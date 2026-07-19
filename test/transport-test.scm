;; Tests for nrepl-server/transport.scm
;; Exercised over in-memory bytevector ports — no socket needed at the unit level.
(require "steel-test/test.scm")
(require "../nrepl-server/transport.scm")

;; Write one message, read it back.
(define (round-trip msg)
  (let ([out (open-output-bytevector)])
    (write-message out msg)
    (read-message (open-input-bytevector (get-output-bytevector out)))))

;; Write every message in `msgs` to one stream, return a reader over it.
(define (reader-over msgs)
  (let ([out (open-output-bytevector)])
    (for-each (lambda (m) (write-message out m)) msgs)
    (open-input-bytevector (get-output-bytevector out))))

(deftest transport-framing-test
  (testing "framing"
    (testing "a single frame"
      (is (= (hash "op" "eval" "id" "1" "code" "(+ 1 2)")
           (round-trip (hash "op" "eval" "id" "1" "code" "(+ 1 2)")))
        "round-trips"))
    (testing "two frames back to back"
      (let ([in (reader-over (list (hash "id" "1" "op" "clone")
                              (hash "id" "2" "op" "describe")))])
        (is (= (hash "id" "1" "op" "clone") (read-message in)) "frame 1 of 2")
        (is (= (hash "id" "2" "op" "describe") (read-message in)) "frame 2 of 2")
        (is (= 'eof (read-message in)) "eof after the last frame")))
    (testing "an empty stream"
      (is (= 'eof (read-message (open-input-bytevector (string->bytes ""))))
        "is eof, not an error"))))

(deftest transport-non-dict-frame-test
  (testing "a non-dict frame is a protocol error"
    (is (thrown? (read-message (open-input-bytevector (string->bytes "i42e"))))
      "reading an int")
    (is (thrown? (write-message (open-output-bytevector) (list "not" "a" "dict")))
      "writing a list")))

;; make-writer's mutex guarantee is a threading property covered by the server
;; design; here we only pin its functional equivalence to write-message.
(deftest transport-make-writer-test
  (testing "make-writer"
    (let ([wa (open-output-bytevector)] [wb (open-output-bytevector)])
      ((make-writer wa) (hash "id" "7" "status" (list "done")))
      (write-message wb (hash "id" "7" "status" (list "done")))
      (is (= (get-output-bytevector wb) (get-output-bytevector wa))
        "emits the same bytes as write-message"))))
