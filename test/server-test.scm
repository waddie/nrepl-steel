;; Tests for nrepl-server/server.scm — the connection serve loop.
;;
;; This drives `serve-loop` over IN-MEMORY byte ports (a bytevector of pre-encoded
;; requests in, a capturing writer out) with the real registry / evaluator / dispatch.
;; It deterministically exercises the whole server pipeline EXCEPT the thin tcp accept
;; wiring.
;;
;; Why not a real-socket test in the suite: a client and server sharing ONE Steel
;; runtime deadlock on a tight bencode request/response loop — Steel's in-process
;; native-thread scheduling starves one side during message I/O (an inter-op flush can
;; mask it, but it is not reliable). This is purely an in-process artifact; an external
;; client (separate process, e.g. nrepl.hx in Phase 7) is unaffected, which is why the
;; standalone clone+eval-over-socket probes work. So socket-level verification is left
;; to the manual/Phase-7 external-client path; the suite tests the loop deterministically.
(require "harness.scm")
(require "../nrepl-server/server.scm")
(require "../nrepl-server/session.scm")
(require "../nrepl-server/evaluator.scm")
(require "../nrepl-server/bencode.scm")

;; Decode every bencode value from a bytevector into a list.
(define (decode-all bv)
  (define in (open-input-bytevector bv))
  (let loop ([acc '()])
    (if (eof-object? (peek-byte in))
      (reverse acc)
      (loop (cons (bencode-decode in) acc)))))

;; Concatenate encoded requests into one input stream.
(define (encode-requests reqs)
  (let loop ([reqs reqs] [acc (bytes)])
    (if (null? reqs)
      acc
      (loop (cdr reqs) (bytes-append acc (bencode-encode (car reqs)))))))

;; Run serve-loop over an in-memory request stream; return the decoded responses.
(define (serve reg reqs)
  (define reader (open-input-bytevector (encode-requests reqs)))
  (define out (open-output-bytevector))
  (serve-loop reader (lambda (m) (write-bytes (bencode-encode m) out)) reg)
  (decode-all (get-output-bytevector out)))

(define (collect resps key)
  (filter (lambda (x) (not (equal? x 'none)))
    (map (lambda (r) (if (hash-contains? r key) (hash-ref r key) 'none)) resps)))
(define (responses-for resps id)
  (filter (lambda (r) (equal? (hash-try-get r "id") id)) resps))

;; Pre-create a session so requests can reference its id (clone's id is generated).
(define reg (make-registry (make-standalone-evaluator)))
(define sid (registry-clone! reg))

(define R
  (serve reg
    (list (hash "op" "eval" "id" "1" "session" sid "code" "(+ 40 2)")
      (hash "op" "eval" "id" "2" "session" sid "code" "(define yy 99)")
      (hash "op" "eval" "id" "3" "session" sid "code" "yy")
      (hash "op" "eval" "id" "4" "session" sid "code" "(display \"so\")")
      (hash "op" "eval" "id" "5" "session" sid "code" "(car '())")
      (hash "op" "describe" "id" "6")
      (hash "op" "ls-sessions" "id" "7")
      (hash "op" "bogus-op" "id" "8"))))

;; The loop answered every request, each terminated by a "done".
(check-equal? "every request gets a done"
  (length (filter (lambda (r) (and (hash-contains? r "status")
                               (member "done" (hash-ref r "status"))))
           R))
  8)

(check-equal? "eval value over serve-loop" (collect (responses-for R "1") "value") (list "42"))
(check-equal? "eval state persists over serve-loop" (collect (responses-for R "3") "value") (list "99"))
(check-equal? "eval out captured over serve-loop" (collect (responses-for R "4") "out") (list "so"))
(check-true "eval error over serve-loop"
  (and (member "eval-error" (hash-ref (last (responses-for R "5")) "status")) #t))
(check-true "describe over serve-loop" (hash-contains? (car (responses-for R "6")) "ops"))
(check-true "ls-sessions over serve-loop lists session"
  (and (member sid (hash-ref (car (responses-for R "7")) "sessions")) #t))
(check-true "unknown-op over serve-loop"
  (and (member "unknown-op" (hash-ref (car (responses-for R "8")) "status")) #t))

;; A bencode framing error stops the loop cleanly (returns, doesn't loop forever).
(check-true "serve-loop survives a malformed frame"
  (let ([reader (open-input-bytevector (string->bytes "xnot-bencode"))]
        [n (box 0)])
    (serve-loop reader (lambda (m) (set-box! n (+ 1 (unbox n)))) reg)
    #t))
