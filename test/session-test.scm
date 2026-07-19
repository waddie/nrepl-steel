;; Tests for nrepl-server/session.scm + evaluator.scm
;; Drives the evaluator directly — no transport, no sockets.
;;
;; The registry and its two sessions are built once at load time; the tests below
;; run in definition order and share that state, so the persistence and isolation
;; tests see the definitions the earlier tests made.
(require "steel-test/test.scm")
(require "../nrepl-server/evaluator.scm")
(require "../nrepl-server/session.scm")

(define reg (make-registry (make-native-evaluator)))
(define sid (registry-clone! reg))
(define sid2 (registry-clone! reg))

(deftest session-clone-test
  (testing "clone"
    (is (string? sid) "returns a string id")
    (is (= 36 (string-length sid)) "the id is uuid-shaped")
    (is (not (equal? sid sid2)) "each session gets a distinct id")))

(deftest session-eval-value-test
  (testing "eval"
    (testing "a single form"
      (let ([r (registry-eval reg sid "(+ 1 2)")])
        (is (= 'ok (hash-ref r 'status)))
        (is (= (list "3") (hash-ref r 'value)))
        (is (= "" (hash-ref r 'out)) "no output")
        (is (= #f (hash-ref r 'ex)) "no exception")))
    (testing "multiple forms"
      ;; one rendered value per form, with the void from `define` dropped
      (is (= (list "18") (hash-ref (registry-eval reg sid "(define q 9) (* q 2)") 'value))
        "void define is dropped"))))

(deftest session-output-capture-test
  (testing "output capture"
    (let ([r (registry-eval reg sid "(display \"hi\")")])
      (is (= "hi" (hash-ref r 'out)) "stdout is captured")
      (is (= '() (hash-ref r 'value)) "display's void result is dropped"))
    (testing "between evals"
      (registry-eval reg sid "(display \"one\")")
      (is (= "two" (hash-ref (registry-eval reg sid "(display \"two\")") 'out))
        "ports are reset, so output does not accumulate"))))

(deftest session-eval-error-test
  (testing "an erroring eval"
    (let ([r (registry-eval reg sid "(car '())")])
      (is (= 'error (hash-ref r 'status)) "reports error status")
      (is (string? (hash-ref r 'ex)) "carries ex as a string")
      (is (= '() (hash-ref r 'value)) "yields no value"))))

(deftest session-state-persistence-test
  (testing "state persists across separate evals in one session"
    (registry-eval reg sid "(define counter 10)")
    (registry-eval reg sid "(set! counter (+ counter 5))")
    (is (= (list "15") (hash-ref (registry-eval reg sid "counter") 'value)))
    ;; The evaluator returns one rendered value PER FORM, and Steel's set! returns
    ;; the PRIOR value (not void), so this two-form eval yields two values. Uses its
    ;; own variable so as not to disturb `counter`.
    (testing "one value per form"
      (registry-eval reg sid "(define tmp 1)")
      (is (= (list "1" "100")
           (hash-ref (registry-eval reg sid "(set! tmp 100) tmp") 'value))
        "set! contributes its prior value"))))

(deftest session-isolation-test
  (testing "sessions are isolated"
    (is (= 'error (hash-ref (registry-eval reg sid2 "counter") 'status))
      "the second session does not see the first's defs")
    (is (= (list "15") (hash-ref (registry-eval reg sid "counter") 'value))
      "the first session still has its own")))

(deftest session-registry-bookkeeping-test
  (testing "registry bookkeeping"
    (is (and (member sid (registry-ids reg)) (member sid2 (registry-ids reg)) #t)
      "ls lists both sessions")
    (testing "close"
      (is (= #t (registry-close! reg sid2)) "returns #t for an open session")
      (is (= #f (registry-close! reg sid2)) "returns #f the second time")
      (is (not (member sid2 (registry-ids reg))) "the session is gone from ls"))
    (testing "eval against a session that is not there"
      (is (thrown? (registry-eval reg sid2 "(+ 1 1)")) "closed session")
      (is (thrown? (registry-eval reg "nope" "(+ 1 1)")) "unknown session"))))
