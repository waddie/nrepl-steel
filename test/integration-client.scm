;; integration-client.scm — a SEPARATE-PROCESS nREPL client that drives a running
;; nrepl-steel server over a real TCP socket and asserts the full stage-one op set.
;;
;;   steel test/integration-client.scm [host:port]      (default 127.0.0.1:7899)
;;
;; This is the Phase 7 acceptance gate. nrepl.hx itself only runs interactively inside
;; Helix and exposes no headless harness (its nrepl-rs client is an async Rust lib), so
;; this script stands in for it: it speaks the exact wire protocol nrepl-rs speaks
;; (bencode dicts; correlate by id; act on the `status` token set; `file` = contents for
;; load-file) and exercises clone -> eval (incl. def-then-use) -> out -> error ->
;; load-file -> ls-sessions -> interrupt -> session isolation -> close.
;;
;; MUST run as its own process: a client sharing the server's Steel runtime deadlocks on
;; the request/response loop. The harness raises on any failed assertion, so the process
;; exits non-zero for the orchestrator.

(require "harness.scm")
(require "../nrepl-server/transport.scm")
(require-builtin steel/tcp)

(define (addr-from-args)
  (define args (command-line))
  (if (>= (length args) 3) (list-ref args 2) "127.0.0.1:7899"))

;; Send one request and collect responses until the one carrying "done" in `status`.
(define (req! rd wr m)
  (write-message wr m)
  (let loop ([acc '()])
    (define r (read-message rd))
    (define acc* (cons r acc))
    (if (and (hash? r) (hash-contains? r "status") (member "done" (hash-ref r "status")))
      (reverse acc*)
      (loop acc*))))

;; Collect the value of `key` from every response in `resps` that carries it.
(define (collect resps key)
  (filter (lambda (x) (not (equal? x 'none)))
    (map (lambda (r) (if (hash-contains? r key) (hash-ref r key) 'none)) resps)))
(define (last-of xs) (if (null? (cdr xs)) (car xs) (last-of (cdr xs))))
(define (final-status resps) (hash-ref (last-of resps) "status"))
(define (has-token? resps tok) (and (member tok (final-status resps)) #t))

;; --- connect ---------------------------------------------------------------
(define addr (addr-from-args))
(define c (tcp-connect addr))
(define rd (tcp-stream-buffered-reader c))
(define wr (tcp-stream-writer c))

;; --- describe (nrepl.hx sends this first on connect) -----------------------
(define desc (req! rd wr (hash "op" "describe" "id" "d1")))
(check-true "describe: advertises eval + load-file"
  (let ([ops (hash-ref (car desc) "ops")])
    (and (hash-contains? ops "eval") (hash-contains? ops "load-file"))))
(check-true "describe: has versions" (hash-contains? (car desc) "versions"))

;; --- clone -----------------------------------------------------------------
(define cl (req! rd wr (hash "op" "clone" "id" "1")))
(define sid (hash-ref (car cl) "new-session"))
(check-true "clone: new-session is a string" (string? sid))

;; --- eval: value -----------------------------------------------------------
(define ev (req! rd wr (hash "op" "eval" "id" "2" "session" sid "code" "(+ 40 2)")))
(check-equal? "eval: value" (collect ev "value") (list "42"))
(check-equal? "eval: echoes session" (hash-ref (last-of ev) "session") sid)

;; --- eval: define then use it (state persistence) --------------------------
(req! rd wr (hash "op" "eval" "id" "3" "session" sid "code" "(define answer 7)"))
(define ev3 (req! rd wr (hash "op" "eval" "id" "4" "session" sid "code" "answer")))
(check-equal? "eval: defs persist across evals" (collect ev3 "value") (list "7"))

;; --- eval: captured stdout -------------------------------------------------
(define evo (req! rd wr (hash "op" "eval" "id" "5" "session" sid "code" "(display \"hi\")")))
(check-equal? "eval: out captured" (collect evo "out") (list "hi"))

;; --- eval: error -> eval-error + ex ----------------------------------------
(define eve (req! rd wr (hash "op" "eval" "id" "6" "session" sid "code" "(car '())")))
(check-true "eval error: eval-error token" (has-token? eve "eval-error"))
(check-true "eval error: ex present" (string? (hash-ref (last-of eve) "ex")))
(check-equal? "eval error: no value" (collect eve "value") '())

;; --- load-file -------------------------------------------------------------
(define lf (req! rd wr (hash "op" "load-file" "id" "7" "session" sid
                        "file"
                        "(define from-file 11)\n(* from-file 2)"
                        "file-name"
                        "scratch.scm")))
(check-equal? "load-file: value of last form" (collect lf "value") (list "22"))
(define lfp (req! rd wr (hash "op" "eval" "id" "8" "session" sid "code" "from-file")))
(check-equal? "load-file: defs persist" (collect lfp "value") (list "11"))

;; --- ls-sessions -----------------------------------------------------------
(define ls (req! rd wr (hash "op" "ls-sessions" "id" "9")))
(check-true "ls-sessions: lists our session"
  (and (member sid (hash-ref (car ls) "sessions")) #t))

;; --- completions (over the wire: list of candidate dicts) ------------------
(define cmp (req! rd wr (hash "op" "completions" "id" "c1" "session" sid "prefix" "from-")))
(check-true "completions: from-file is a candidate"
  (let ([names (map (lambda (c) (hash-ref c "candidate")) (hash-ref (car cmp) "completions"))])
    (and (member "from-file" names) #t)))
(check-true "completions: candidates carry a type"
  (hash-contains? (car (hash-ref (car cmp) "completions")) "type"))

;; --- lookup / info (over the wire: nested info dict) -----------------------
(define lk (req! rd wr (hash "op" "lookup" "id" "k1" "session" sid "sym" "map")))
(check-true "lookup: info dict names the symbol"
  (equal? (hash-ref (hash-ref (car lk) "info") "name") "map"))
(check-true "lookup: info carries a doc string"
  (string? (hash-ref (hash-ref (car lk) "info") "doc")))
(define lku (req! rd wr (hash "op" "lookup" "id" "k2" "session" sid "sym" "no-such-symbol-xyz")))
(check-true "lookup: unbound symbol -> no-info" (has-token? lku "no-info"))

;; --- interrupt (queued-only: an idle session reports session-idle) ---------
(define intr (req! rd wr (hash "op" "interrupt" "id" "10" "session" sid)))
(check-true "interrupt: idle session" (has-token? intr "session-idle"))

;; --- a second session is isolated ------------------------------------------
(define cl2 (req! rd wr (hash "op" "clone" "id" "11")))
(define sid2 (hash-ref (car cl2) "new-session"))
(check-true "clone: second session has a distinct id" (not (equal? sid sid2)))
;; `answer` was defined in sid only -> referencing it in sid2 must raise.
(define iso (req! rd wr (hash "op" "eval" "id" "12" "session" sid2 "code" "answer")))
(check-true "isolation: sid's def is invisible in sid2" (has-token? iso "eval-error"))

;; --- close -----------------------------------------------------------------
(define cls (req! rd wr (hash "op" "close" "id" "13" "session" sid)))
(check-true "close: done" (member "done" (final-status cls)))
(define ls2 (req! rd wr (hash "op" "ls-sessions" "id" "14")))
(check-true "close: session gone from ls-sessions"
  (not (member sid (hash-ref (car ls2) "sessions"))))

;; --- unknown op ------------------------------------------------------------
(define unk (req! rd wr (hash "op" "no-such-op" "id" "15")))
(check-true "unknown-op: reported" (has-token? unk "unknown-op"))

(tcp-shutdown! c)
(summary!)
