;; Minimal self-contained test harness for the nrepl-steel project.
;;
;; Zero external dependencies — Steel's cogs/tests/unit-test.scm is not installed
;; in STEEL_HOME, and depends on a colors module, so we vendor a tiny runner here
;; (resolves implementation-plan.md open question Q1: hand-rolled runner).
;;
;; Usage:
;;   (require "/abs/path/test/harness.scm")
;;   (check-equal? "name" actual expected)
;;   (check-true   "name" expr)
;;   (check-err?   "name" expr-that-should-raise)
;;   (summary!)            ; prints stats; raises (=> rc 1) if anything failed
;;
;; `summary!` raises an uncaught error on failure so `steel test/...` exits non-zero
;; (Steel has no `exit` primitive in the base environment, but an uncaught error
;; yields process rc=1, which is what a CI runner needs).

(provide check-equal?
  check-true
  check-err?
  summary!
  reset-stats!
  get-stats)

(define *passed* 0)
(define *failed* 0)
(define *failures* '())

(define (reset-stats!)
  (set! *passed* 0)
  (set! *failed* 0)
  (set! *failures* '()))

(define (get-stats)
  (hash 'passed *passed* 'failed *failed* 'failures (reverse *failures*)))

(define (mark-pass name)
  (set! *passed* (+ *passed* 1))
  (display "  ok   ")
  (displayln name)
  (flush-output-port (current-output-port)))

(define (mark-fail name detail)
  (set! *failed* (+ *failed* 1))
  (set! *failures* (cons name *failures*))
  (display "  FAIL ")
  (displayln name)
  (when detail (begin (display "       ") (displayln detail)))
  (flush-output-port (current-output-port)))

;; Assert (equal? actual expected). Any error raised while computing `actual`
;; counts as a failure rather than aborting the whole suite.
(define-syntax check-equal?
  (syntax-rules ()
    ;; NB: Steel's syntax-rules substitutes pattern variables even inside quoted
    ;; literals, so a label like 'expected here would be rewritten to the matched
    ;; expression. Use plain strings for labels to stay clear of that.
    [(_ name actual expected)
      (with-handler
        (lambda (err) (mark-fail name (list "raised" err)))
        (let ([a actual] [e expected])
          (if (equal? a e)
            (mark-pass name)
            (mark-fail name (list "want" e "got" a)))))]))

;; Assert a truthy value.
(define-syntax check-true
  (syntax-rules ()
    [(_ name expr)
      (with-handler
        (lambda (err) (mark-fail name (list "raised" err)))
        (if expr (mark-pass name) (mark-fail name (list "expected truthy, got" #f))))]))

;; Assert that evaluating `expr` raises an error.
(define-syntax check-err?
  (syntax-rules ()
    [(_ name expr)
      (with-handler
        (lambda (err) (mark-pass name))
        (begin expr (mark-fail name "expected an error, but none was raised")))]))

;; Print a summary line and, if any test failed, raise so the process exits rc=1.
(define (summary!)
  (newline)
  (display (int->string *passed*))
  (display " passed, ")
  (display (int->string *failed*))
  (displayln " failed")
  (when (> *failed* 0)
    (error "test suite had failures:" (reverse *failures*))))

(define (int->string n) (to-string n))
