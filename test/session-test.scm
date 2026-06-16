;; Tests for nrepl-server/session.scm + evaluator.scm
;; Drives the evaluator directly — no transport, no sockets.
(require "harness.scm")
(require "../nrepl-server/evaluator.scm")
(require "../nrepl-server/session.scm")

(define (fresh-registry) (make-registry (make-native-evaluator)))

;; --- basic value evaluation ------------------------------------------------
(define reg (fresh-registry))
(define sid (registry-clone! reg))

(check-true "clone returns a string id" (string? sid))
(check-equal? "session id is uuid-shaped length" (string-length sid) 36)

(define r1 (registry-eval reg sid "(+ 1 2)"))
(check-equal? "value: status ok" (hash-ref r1 'status) 'ok)
(check-equal? "value: rendered" (hash-ref r1 'value) (list "3"))
(check-equal? "value: no output" (hash-ref r1 'out) "")
(check-equal? "value: no ex" (hash-ref r1 'ex) #f)

;; multiple forms -> one rendered value each, void (define) dropped
(define r2 (registry-eval reg sid "(define q 9) (* q 2)"))
(check-equal? "multi-form drops void define" (hash-ref r2 'value) (list "18"))

;; --- output capture + reset between evals ----------------------------------
(define ro (registry-eval reg sid "(display \"hi\")"))
(check-equal? "captured stdout" (hash-ref ro 'out) "hi")
(check-equal? "display value is void/dropped" (hash-ref ro 'value) '())

(registry-eval reg sid "(display \"one\")")
(define rtwo (registry-eval reg sid "(display \"two\")"))
(check-equal? "ports reset between evals (no accumulation)" (hash-ref rtwo 'out) "two")

;; --- errors map to status/ex ----------------------------------------------
(define re (registry-eval reg sid "(car '())"))
(check-equal? "error: status" (hash-ref re 'status) 'error)
(check-true "error: ex is a string" (string? (hash-ref re 'ex)))
(check-equal? "error: no value" (hash-ref re 'value) '())

;; --- state persists across evals within a session --------------------------
(registry-eval reg sid "(define counter 10)")
(registry-eval reg sid "(set! counter (+ counter 5))")
(check-equal? "state persists across separate evals"
  (hash-ref (registry-eval reg sid "counter") 'value)
  (list "15"))

;; The evaluator returns one rendered value PER FORM. Note Steel's set! returns the
;; PRIOR value (not void), so a two-form eval yields two values here. Uses its own
;; variable so as not to disturb `counter`.
(registry-eval reg sid "(define tmp 1)")
(check-equal? "one value per form (set! returns prior value in Steel)"
  (hash-ref (registry-eval reg sid "(set! tmp 100) tmp") 'value)
  (list "1" "100"))

;; --- sessions are isolated -------------------------------------------------
(define sid2 (registry-clone! reg))
(check-equal? "second session does not see first's defs"
  (hash-ref (registry-eval reg sid2 "counter") 'status)
  'error)
(check-equal? "first session still has its def"
  (hash-ref (registry-eval reg sid "counter") 'value)
  (list "15"))

;; --- registry bookkeeping --------------------------------------------------
(check-true "ls lists both sessions"
  (and (member sid (registry-ids reg)) (member sid2 (registry-ids reg)) #t))
(check-equal? "close returns #t" (registry-close! reg sid2) #t)
(check-equal? "close again returns #f" (registry-close! reg sid2) #f)
(check-true "closed session gone from ls" (not (member sid2 (registry-ids reg))))
(check-err? "eval on closed session errors" (registry-eval reg sid2 "(+ 1 1)"))
(check-err? "eval on unknown session errors" (registry-eval reg "nope" "(+ 1 1)"))
