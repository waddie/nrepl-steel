;; Shared helpers for asserting over lists of nREPL response dicts.
;; Used by the dispatch, server and integration suites, which all reason about a
;; request's responses the same way: correlate by id, read the terminator's status
;; token set, and gather a key from whichever responses carry it.
(provide dict collect last-of final-status has-token? responses-for)

;; Build a request dict from a flat key/value list.
;;
;; Steel 0.8.2 mis-compiles a (hash k v ...) literal of FIVE OR MORE pairs inside a
;; function body — the pairs are spliced into the enclosing call's argument list, so
;; the callee receives "op" where it expected a hash. Top-level forms are unaffected,
;; which is why the pre-steel-test suite never hit this: its requests were built at
;; the top level, whereas a deftest body is a function body. (apply hash <list>) takes
;; a different compile path and is correct, so route wide request dicts through here.
;; Four pairs or fewer as a literal is fine.
(define (dict kvs) (apply hash kvs))

;; Collect the value of `key` from every response in `resps` that carries it.
(define (collect resps key)
  (filter (lambda (x) (not (equal? x 'none)))
    (map (lambda (r) (if (hash-contains? r key) (hash-ref r key) 'none)) resps)))

(define (last-of xs) (if (null? (cdr xs)) (car xs) (last-of (cdr xs))))

;; The terminating response's status token list.
(define (final-status resps) (hash-ref (last-of resps) "status"))

(define (has-token? resps tok) (and (member tok (final-status resps)) #t))

;; Every response correlated to request `id`.
(define (responses-for resps id)
  (filter (lambda (r) (equal? (hash-try-get r "id") id)) resps))
