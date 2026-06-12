;; Tests for nrepl-server/transport.scm
;; Exercised over in-memory bytevector ports — no socket needed at the unit level.
(require "harness.scm")
(require "../nrepl-server/transport.scm")

;; Write one message, read it back.
(define (round-trip msg)
  (define out (open-output-bytevector))
  (write-message out msg)
  (read-message (open-input-bytevector (get-output-bytevector out))))

(check-equal? "single frame round-trips"
  (round-trip (hash "op" "eval" "id" "1" "code" "(+ 1 2)"))
  (hash "op" "eval" "id" "1" "code" "(+ 1 2)"))

;; Two frames written back to back read off one stream in order, then 'eof.
(define out2 (open-output-bytevector))
(write-message out2 (hash "id" "1" "op" "clone"))
(write-message out2 (hash "id" "2" "op" "describe"))
(define in2 (open-input-bytevector (get-output-bytevector out2)))
(check-equal? "frame 1 of 2" (read-message in2) (hash "id" "1" "op" "clone"))
(check-equal? "frame 2 of 2" (read-message in2) (hash "id" "2" "op" "describe"))
(check-equal? "eof after last frame" (read-message in2) 'eof)

;; Empty stream is 'eof, not an error.
(check-equal? "empty stream is eof"
  (read-message (open-input-bytevector (string->bytes "")))
  'eof)

;; A non-dict frame is a protocol error.
(check-err? "non-dict frame rejected"
  (read-message (open-input-bytevector (string->bytes "i42e"))))
(check-err? "writing a non-dict rejected"
  (write-message (open-output-bytevector) (list "not" "a" "dict")))

;; make-writer produces identical bytes to write-message (functional equivalence;
;; its mutex guarantee is a threading property covered by the server design).
(define wa (open-output-bytevector))
(define wb (open-output-bytevector))
(define w (make-writer wa))
(w (hash "id" "7" "status" (list "done")))
(write-message wb (hash "id" "7" "status" (list "done")))
(check-equal? "make-writer matches write-message"
  (get-output-bytevector wa)
  (get-output-bytevector wb))
