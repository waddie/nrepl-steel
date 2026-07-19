;; Tests for nrepl-server/dispatch.scm
;; Feeds synthetic request dicts through dispatch and asserts the response dicts.
;; Uses the real registry+evaluator (in-process, fast) so this also integration-tests
;; the dispatch -> session -> evaluator path at the dict level. No socket.
;;
;; One registry and one session are built at load time and shared; the tests run in
;; definition order, so the session is live until the close test at the end.
(require "steel-test/test.scm")
(require "responses.scm")
(require "../nrepl-server/evaluator.scm")
(require "../nrepl-server/session.scm")
(require "../nrepl-server/dispatch.scm")
(require "../nrepl-server/version.scm")

(define reg (make-registry (make-native-evaluator)))
(define clone-resps (dispatch reg (hash "op" "clone" "id" "1")))
(define sid (hash-ref (car clone-resps) "new-session"))
(define desc (dispatch reg (hash "op" "describe" "id" "d1")))
(define desc-ops (hash-ref (car desc) "ops"))

(deftest dispatch-clone-test
  (testing "clone"
    (is (= 1 (length clone-resps)) "answers with one response")
    (is (= "1" (hash-ref (car clone-resps) "id")) "echoes the request id")
    (is (string? (hash-ref (car clone-resps) "new-session")) "new-session is a string")
    (is (has-token? clone-resps "done"))))

(deftest dispatch-describe-test
  (testing "describe"
    (testing "advertises the stage-one op set"
      (is (and (hash-contains? desc-ops "clone")
           (hash-contains? desc-ops "eval")
           (hash-contains? desc-ops "describe")
           (hash-contains? desc-ops "close")
           (hash-contains? desc-ops "ls-sessions")
           (hash-contains? desc-ops "interrupt"))
        "core ops")
      (is (hash-contains? desc-ops "load-file") "load-file")
      (is (and (hash-contains? desc-ops "completions")
           (hash-contains? desc-ops "lookup")
           (hash-contains? desc-ops "info"))
        "introspection ops"))
    (testing "versions"
      (is (hash-contains? (car desc) "versions") "are reported")
      ;; Guards the version.scm require wiring — describe must report the
      ;; single-sourced version, not a literal that can drift.
      (is (= nrepl-steel-version
           (hash-ref (hash-ref (hash-ref (car desc) "versions") "nrepl-steel")
             "version-string"))
        "nrepl-steel's version is single-sourced"))
    (is (has-token? desc "done"))))

(deftest dispatch-eval-test
  (testing "eval"
    (testing "returning a value"
      (let ([ev (dispatch reg (hash "op" "eval" "id" "2" "session" sid "code" "(+ 1 2)"))])
        (is (= (list "3") (collect ev "value")))
        (is (= sid (hash-ref (last-of ev) "session")) "echoes the session")
        (is (has-token? ev "done"))
        (is (not (has-token? ev "eval-error")) "is not an error")))
    (testing "writing to stdout"
      (is (= (list "hi")
           (collect (dispatch reg (hash "op" "eval" "id" "3" "session" sid
                                   "code"
                                   "(display \"hi\")"))
             "out"))
        "output is captured"))
    (testing "raising"
      (let ([eve (dispatch reg (hash "op" "eval" "id" "4" "session" sid
                                "code"
                                "(car '())"))])
        (is (has-token? eve "eval-error"))
        (is (string? (hash-ref (last-of eve) "ex")) "ex is present")
        (is (= '() (collect eve "value")) "no value is reported")))
    (testing "without a usable session"
      (is (has-token? (dispatch reg (hash "op" "eval" "id" "5" "code" "1")) "error")
        "no session")
      (is (has-token? (dispatch reg (hash "op" "eval" "id" "6" "session" "nope" "code" "1"))
           "error")
        "unknown session"))))

(deftest dispatch-load-file-test
  ;; `file` carries the file contents; multiple forms yield one value per form and
  ;; definitions persist in the session just like eval.
  (testing "load-file"
    (let ([lf (dispatch reg (hash "op" "load-file" "id" "lf1" "session" sid
                             "file"
                             "(define lf-a 10)\n(+ lf-a 5)"))])
      (is (= (list "15") (collect lf "value")) "reports the value of the last form")
      (is (has-token? lf "done")))
    (is (= (list "10")
         (collect (dispatch reg (hash "op" "eval" "id" "lf2" "session" sid "code" "lf-a"))
           "value"))
      "its defs persist into a later eval")
    (testing "rejected requests"
      (is (has-token? (dispatch reg (hash "op" "load-file" "id" "lf3" "session" sid)) "error")
        "missing file")
      (is (has-token? (dispatch reg (hash "op" "load-file" "id" "lf4" "session" "nope"
                                     "file"
                                     "1"))
           "error")
        "unknown session"))))

(deftest dispatch-ls-sessions-test
  (testing "ls-sessions"
    (is (and (member sid
              (hash-ref (car (dispatch reg (hash "op" "ls-sessions" "id" "7"))) "sessions"))
         #t)
      "lists the open session")))

(deftest dispatch-completions-test
  ;; sid has lf-a defined (by the load-file test above), so a "lf" prefix surfaces it.
  (testing "completions"
    (let ([cmp (dispatch reg (hash "op" "completions" "id" "c1" "session" sid
                              "prefix"
                              "lf"))])
      (is (has-token? cmp "done"))
      (is (let ([cands (hash-ref (car cmp) "completions")])
           (and (list? cands)
             (> (length cands) 0)
             (hash-contains? (car cands) "candidate")
             (hash-contains? (car cands) "type")))
        "candidate dicts carry candidate + type")
      (is (and (member "lf-a"
                (map (lambda (c) (hash-ref c "candidate")) (hash-ref (car cmp) "completions")))
           #t)
        "lf-a is among the candidates"))
    (testing "rejected requests"
      (is (has-token? (dispatch reg (hash "op" "completions" "id" "c2" "prefix" "x")) "error")
        "no session")
      (is (has-token? (dispatch reg (hash "op" "completions" "id" "c3" "session" "nope"
                                     "prefix"
                                     "x"))
           "error")
        "unknown session"))))

(deftest dispatch-lookup-test
  (testing "lookup"
    (let ([lk (dispatch reg (hash "op" "lookup" "id" "k1" "session" sid "sym" "map"))])
      (is (has-token? lk "done"))
      (is (let ([info (hash-ref (car lk) "info")])
           (and (hash? info) (equal? (hash-ref info "name") "map")))
        "returns an info dict naming the symbol")
      (is (string? (hash-ref (hash-ref (car lk) "info") "doc")) "the info carries a doc"))
    (is (has-token? (dispatch reg (hash "op" "info" "id" "k2" "session" sid "sym" "map"))
         "done")
      "the info op is an alias for lookup")
    (is (has-token? (dispatch reg (hash "op" "lookup" "id" "k3" "session" sid
                                   "sym"
                                   "totally-unbound-xyz"))
         "no-info")
      "an unbound symbol reports no-info")
    (testing "rejected requests"
      (is (has-token? (dispatch reg (hash "op" "lookup" "id" "k4" "session" sid)) "error")
        "missing sym")
      (is (has-token? (dispatch reg (hash "op" "lookup" "id" "k5" "session" "nope"
                                     "sym"
                                     "map"))
           "error")
        "unknown session"))))

(deftest dispatch-interrupt-test
  ;; Queued-only: the synchronous registry is never mid-eval when interrupt lands.
  (testing "interrupt"
    (is (has-token? (dispatch reg (hash "op" "interrupt" "id" "8" "session" sid))
         "session-idle")
      "an idle session reports session-idle")
    (is (has-token? (dispatch reg (hash "op" "interrupt" "id" "8b" "session" "nope")) "error")
      "unknown session")
    (is (let ([resps (dispatch reg (hash "op" "interrupt" "id" "8c"))])
         (and (has-token? resps "error") (has-token? resps "no-session")))
      "no session")))

(deftest dispatch-close-test
  (testing "close"
    (is (has-token? (dispatch reg (hash "op" "close" "id" "9" "session" sid)) "done"))
    (is (not (member sid
              (hash-ref (car (dispatch reg (hash "op" "ls-sessions" "id" "10")))
                "sessions")))
      "the session is gone from ls-sessions")))

(deftest dispatch-unknown-op-test
  (testing "an unknown op"
    (let ([unk (dispatch reg (hash "op" "frobnicate" "id" "11"))])
      (is (has-token? unk "unknown-op"))
      (is (has-token? unk "error"))
      (is (= "11" (hash-ref (car unk) "id")) "echoes the request id"))))
