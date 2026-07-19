;; integration-client.scm — a SEPARATE-PROCESS nREPL client that drives a running
;; nrepl-steel server over a real TCP socket and asserts the full stage-one op set.
;;
;;   steel test/integration-client.scm [host:port]      (default 127.0.0.1:7899)
;;
;; This is the acceptance gate. nrepl.hx itself only runs interactively inside Helix
;; and exposes no headless harness (its nrepl-rs client is an async Rust lib), so this
;; script stands in for it: it speaks the exact wire protocol nrepl-rs speaks (bencode
;; dicts; correlate by id; act on the `status` token set; `file` = contents for
;; load-file) and exercises clone -> eval (incl. def-then-use) -> out -> error ->
;; load-file -> ls-sessions -> interrupt -> session isolation -> close.
;;
;; MUST run as its own process: a client sharing the server's Steel runtime deadlocks on
;; the request/response loop. run-tests! raises on any failed assertion, so the process
;; exits non-zero for the orchestrator.
;;
;; The tests run in definition order against one connection and one session, so the
;; later tests see the definitions the earlier ones made.
(require "steel-test/test.scm")
(require "responses.scm")
(require "../nrepl-server/transport.scm")
(require-builtin steel/tcp)

(define (addr-from-args)
  (let ([args (command-line)])
    (if (>= (length args) 3) (list-ref args 2) "127.0.0.1:7899")))

;; Send one request and collect responses until the one carrying "done" in `status`.
(define (req! rd wr m)
  (write-message wr m)
  (let loop ([acc '()])
    (let ([r (read-message rd)])
      (if (and (hash? r) (hash-contains? r "status") (member "done" (hash-ref r "status")))
        (reverse (cons r acc))
        (loop (cons r acc))))))

;; --- connect ---------------------------------------------------------------
(define c (tcp-connect (addr-from-args)))
(define rd (tcp-stream-buffered-reader c))
(define wr (tcp-stream-writer c))

;; Close the socket once the whole suite has run, before run-tests! raises on failure.
(use-fixtures 'once
  (lambda (run)
    (run)
    (tcp-shutdown! c)))

;; describe is what nrepl.hx sends first on connect; clone gives us the session the
;; rest of the suite works in.
(define desc (req! rd wr (hash "op" "describe" "id" "d1")))
(define cl (req! rd wr (hash "op" "clone" "id" "1")))
(define sid (hash-ref (car cl) "new-session"))

(deftest wire-describe-test
  (testing "describe over the wire"
    (is (let ([ops (hash-ref (car desc) "ops")])
         (and (hash-contains? ops "eval") (hash-contains? ops "load-file")))
      "advertises eval + load-file")
    (is (hash-contains? (car desc) "versions") "reports versions")))

(deftest wire-clone-test
  (testing "clone over the wire"
    (is (string? sid) "new-session is a string")))

(deftest wire-eval-test
  (testing "eval over the wire"
    (testing "returning a value"
      (let ([ev (req! rd wr (hash "op" "eval" "id" "2" "session" sid "code" "(+ 40 2)"))])
        (is (= (list "42") (collect ev "value")))
        (is (= sid (hash-ref (last-of ev) "session")) "echoes the session")))
    (testing "defining then using"
      (req! rd wr (hash "op" "eval" "id" "3" "session" sid "code" "(define answer 7)"))
      (is (= (list "7")
           (collect (req! rd wr (hash "op" "eval" "id" "4" "session" sid "code" "answer"))
             "value"))
        "defs persist across evals"))
    (testing "writing to stdout"
      (is (= (list "hi")
           (collect (req! rd wr (hash "op" "eval" "id" "5" "session" sid
                                 "code"
                                 "(display \"hi\")"))
             "out"))
        "output is captured"))
    (testing "raising"
      (let ([eve (req! rd wr (hash "op" "eval" "id" "6" "session" sid "code" "(car '())"))])
        (is (has-token? eve "eval-error"))
        (is (string? (hash-ref (last-of eve) "ex")) "ex is present")
        (is (= '() (collect eve "value")) "no value is reported")))))

(deftest wire-load-file-test
  (testing "load-file over the wire"
    ;; Five pairs, so this one must go through `dict` (see responses.scm). `file-name`
    ;; is accepted and ignored by the server; it rides along to prove that.
    (is (= (list "22")
         (collect (req! rd wr (dict (list "op" "load-file" "id" "7" "session" sid
                                     "file"
                                     "(define from-file 11)\n(* from-file 2)"
                                     "file-name"
                                     "scratch.scm")))
           "value"))
      "reports the value of the last form")
    (is (= (list "11")
         (collect (req! rd wr (hash "op" "eval" "id" "8" "session" sid "code" "from-file"))
           "value"))
      "its defs persist")))

(deftest wire-ls-sessions-test
  (testing "ls-sessions over the wire"
    (is (and (member sid
              (hash-ref (car (req! rd wr (hash "op" "ls-sessions" "id" "9"))) "sessions"))
         #t)
      "lists our session")))

(deftest wire-completions-test
  (testing "completions over the wire"
    (let ([cmp (req! rd wr (hash "op" "completions" "id" "c1" "session" sid
                            "prefix"
                            "from-"))])
      (is (and (member "from-file"
                (map (lambda (x) (hash-ref x "candidate")) (hash-ref (car cmp) "completions")))
           #t)
        "from-file is a candidate")
      (is (hash-contains? (car (hash-ref (car cmp) "completions")) "type")
        "candidates carry a type"))))

(deftest wire-lookup-test
  (testing "lookup over the wire"
    (let ([lk (req! rd wr (hash "op" "lookup" "id" "k1" "session" sid "sym" "map"))])
      (is (= "map" (hash-ref (hash-ref (car lk) "info") "name"))
        "the info dict names the symbol")
      (is (string? (hash-ref (hash-ref (car lk) "info") "doc")) "the info carries a doc"))
    (is (has-token? (req! rd wr (hash "op" "lookup" "id" "k2" "session" sid
                                 "sym"
                                 "no-such-symbol-xyz"))
         "no-info")
      "an unbound symbol reports no-info")))

(deftest wire-interrupt-test
  ;; Queued-only, so an idle session is all we can assert over the wire.
  (testing "interrupt over the wire"
    (is (has-token? (req! rd wr (hash "op" "interrupt" "id" "10" "session" sid))
         "session-idle")
      "an idle session reports session-idle")))

(deftest wire-session-isolation-test
  (testing "a second session over the wire"
    (let ([sid2 (hash-ref (car (req! rd wr (hash "op" "clone" "id" "11"))) "new-session")])
      (is (not (equal? sid sid2)) "has a distinct id")
      ;; `answer` was defined in sid only, so referencing it in sid2 must raise.
      (is (has-token? (req! rd wr (hash "op" "eval" "id" "12" "session" sid2
                                   "code"
                                   "answer"))
           "eval-error")
        "does not see sid's defs"))))

(deftest wire-close-test
  (testing "close over the wire"
    (is (has-token? (req! rd wr (hash "op" "close" "id" "13" "session" sid)) "done"))
    (is (not (member sid
              (hash-ref (car (req! rd wr (hash "op" "ls-sessions" "id" "14")))
                "sessions")))
      "the session is gone from ls-sessions")))

(deftest wire-unknown-op-test
  (testing "an unknown op over the wire"
    (is (has-token? (req! rd wr (hash "op" "no-such-op" "id" "15")) "unknown-op")
      "is reported")))

(run-tests!)
