;; session.scm — the session registry: session-id <-> backend state.
;;
;; Holds one evaluator backend (the seam) and a table of live sessions. `clone` makes a
;; fresh backend state and a new id; `eval` routes code to a session's state; `close`
;; tears the backend down and drops the entry. Deliberately ignorant of the backend's
;; nature — it only calls Evaluator-init/eval/close.
;;
;; Concurrency note: this registry is synchronous. Per-session serialization of evals
;; and the worker-thread/channel model are layered on at the server loop (Phase 6) —
;; and that choice is reopened by the interrupt findings (see spike-interrupt.md), so
;; it is kept out of this module rather than baked in here.

(require "evaluator.scm")
(require-builtin steel/random)

(provide make-registry
  registry-clone!
  registry-get
  registry-eval
  registry-close!
  registry-ids
  Session?
  Session-id
  Session-state)

(struct Session (id state))
(struct Registry (evaluator table) #:mutable)

;; A registry is created with the evaluator backend to use for every session.
(define (make-registry evaluator) (Registry evaluator (hash)))

;; --- session ids -----------------------------------------------------------
;; nREPL session ids are opaque strings to the client; we mint UUID-shaped ones from
;; the RNG (steel/random) for familiarity (implementation-plan.md Q3).
(define (hex4 n)
  (define s (number->string n 16))
  (string-append (make-string (- 4 (string-length s)) #\0) s))
(define (rand16) (rng->gen-range 0 65536))
(define (gen-session-id)
  (string-append (hex4 (rand16)) (hex4 (rand16)) "-" (hex4 (rand16)) "-"
    (hex4 (rand16))
    "-"
    (hex4 (rand16))
    "-"
    (hex4 (rand16))
    (hex4 (rand16))
    (hex4 (rand16))))

;; --- registry operations ---------------------------------------------------

(define (registry-clone! reg)
  (define state ((Evaluator-init (Registry-evaluator reg))))
  (define id (gen-session-id))
  (set-Registry-table! reg (hash-insert (Registry-table reg) id (Session id state)))
  id)

(define (registry-get reg id)
  (and (hash-contains? (Registry-table reg) id)
    (hash-ref (Registry-table reg) id)))

;; Evaluate code in session `id`. Returns a result hash (see evaluator.scm), or raises
;; if the session is unknown — dispatch turns that into an nREPL error status.
(define (registry-eval reg id code)
  (define s (registry-get reg id))
  (unless s (error "registry-eval: unknown session" id))
  ((Evaluator-eval (Registry-evaluator reg)) (Session-state s) code))

;; Close session `id`. Returns #t if it existed, #f otherwise.
(define (registry-close! reg id)
  (define s (registry-get reg id))
  (cond
    [s ((Evaluator-close (Registry-evaluator reg)) (Session-state s))
      (set-Registry-table! reg (hash-remove (Registry-table reg) id))
      #t]
    [else #f]))

(define (registry-ids reg) (hash-keys->list (Registry-table reg)))
