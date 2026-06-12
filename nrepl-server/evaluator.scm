;; evaluator.scm — the evaluation seam.
;;
;; Evaluation is a single indirection so the rest of the server (bencode / transport /
;; session / dispatch) never knows how code is actually run. An Evaluator is three
;; procedures:
;;
;;   init  : () -> state            ;; create a fresh isolated session backend
;;   eval  : state, code -> result  ;; run code, return a result hash (below)
;;   close : state -> void          ;; tear the backend down
;;
;; Stage one ships the *standalone* backend: one Steel (Engine::new) per session,
;; evaluated with run!, with the mandatory per-session output-capture prelude. A future
;; Helix backend would swap in init/eval/close that marshal onto the editor loop —
;; nothing else changes.
;;
;; A result hash has:
;;   'status : 'ok | 'error
;;   'value  : list of rendered value strings (one per evaluated form; void results
;;             — definitions, side effects — are dropped)
;;   'out    : captured stdout (string, possibly "")
;;   'err    : captured stderr (string, possibly "")
;;   'ex     : exception text when 'status is 'error, else #f

(require "steel/result")

(provide Evaluator Evaluator? Evaluator-init Evaluator-eval Evaluator-close
  make-standalone-evaluator)

(struct Evaluator (init eval close))

;; --- standalone backend: a child engine per session ------------------------

;; Install the capture prelude once, at session creation. This is MANDATORY — without
;; it, evaluated output leaks to the server's own stdout (see spike-output-capture.md).
;; The current-port parameter bindings persist across run! calls.
(define (install-capture-prelude! e)
  (run! e "(define __out (open-output-string))")
  (run! e "(define __err (open-output-string))")
  (run! e "(current-output-port __out)")
  (run! e "(current-error-port __err)")
  e)

;; Drain a capture port to a string (its run! result is a one-element list).
(define (drain! e name)
  (car (unwrap-ok (run! e (string-append "(get-output-string " name ")")))))

;; Recreate a capture port after draining — draining does NOT clear it, so without a
;; reset, output would accumulate across evals.
(define (reset-port! e var current-port-fn)
  (run! e (string-append "(set! " var " (open-output-string))"))
  (run! e (string-append "(" current-port-fn " " var ")")))

(define (void-render? s) (equal? s "#<void>"))

(define (standalone-eval e code)
  ;; run! maps user code to (Ok values) / (Err error). A throw from run! itself
  ;; (e.g. a read/compile failure surfaced as an exception) is folded into an Err so
  ;; the ports still get drained and reset below.
  (define r (with-handler (lambda (err) (Err err)) (run! e code)))
  (define out (drain! e "__out"))
  (define err (drain! e "__err"))
  (reset-port! e "__out" "current-output-port")
  (reset-port! e "__err" "current-error-port")
  (if (Ok? r)
    (hash 'status 'ok
      'value
      (filter (lambda (s) (not (void-render? s)))
        (map value->string (unwrap-ok r)))
      'out
      out
      'err
      err
      'ex
      #f)
    (hash 'status 'error
      'value
      '()
      'out
      out
      'err
      err
      'ex
      (value->string (unwrap-err r)))))

(define (make-standalone-evaluator)
  (Evaluator
    (lambda () (install-capture-prelude! (Engine::new)))
    standalone-eval
    ;; Dropping the registry's reference to the engine is enough for it to be reclaimed
    ;; (Steel is reference-counted); nothing extra to release for the standalone backend.
    (lambda (e) void)))
