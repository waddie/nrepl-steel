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
;; it is kept out of this module rather than baked in here. The table itself IS shared
;; across connection threads, though, so the two read-modify-write mutations (clone,
;; close) take the registry lock — without it, concurrent clones from two connections
;; can lose an entry (the immutable-hash swap drops one insert).

(require "evaluator.scm")
(require-builtin steel/random)

(provide make-registry
  registry-clone!
  registry-get
  registry-eval
  registry-complete
  registry-info
  registry-close!
  registry-ids
  Session?
  Session-id
  Session-state)

(struct Session (id state))
(struct Registry (evaluator table lock) #:mutable)

;; A registry is created with the evaluator backend to use for every session.
(define (make-registry evaluator) (Registry evaluator (hash) (mutex)))

;; Run `thunk` holding the registry lock. NB: lock-acquire! returns a guard;
;; lock-release! takes that guard (not the mutex) — same pattern as make-writer.
(define (with-registry-lock reg thunk)
  (define guard (lock-acquire! (Registry-lock reg)))
  (dynamic-wind
    (lambda () void)
    thunk
    (lambda () (lock-release! guard))))

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
  (with-registry-lock reg
    (lambda ()
      (set-Registry-table! reg (hash-insert (Registry-table reg) id (Session id state)))))
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

;; Completion candidates for `prefix` in session `id`: a list of (name type) pairs.
;; Raises if the session is unknown, like registry-eval.
(define (registry-complete reg id prefix)
  (define s (registry-get reg id))
  (unless s (error "registry-complete: unknown session" id))
  ((Evaluator-complete (Registry-evaluator reg)) (Session-state s) prefix))

;; Symbol metadata for `sym` in session `id`: a string->string hash, or #f if unbound.
;; Raises if the session is unknown.
(define (registry-info reg id sym)
  (define s (registry-get reg id))
  (unless s (error "registry-info: unknown session" id))
  ((Evaluator-info (Registry-evaluator reg)) (Session-state s) sym))

;; Close session `id`. Returns #t if it existed, #f otherwise.
(define (registry-close! reg id)
  (define s (registry-get reg id))
  (cond
    [s ((Evaluator-close (Registry-evaluator reg)) (Session-state s))
      (with-registry-lock reg
        (lambda ()
          (set-Registry-table! reg (hash-remove (Registry-table reg) id))))
      #t]
    [else #f]))

(define (registry-ids reg) (hash-keys->list (Registry-table reg)))
