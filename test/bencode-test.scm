;; Tests for nrepl-server/bencode.scm
(require "steel-test/test.scm")
(require "../nrepl-server/bencode.scm")

(define (dec s) (bencode-decode-bytes (string->bytes s)))
(define (round-trips? v) (equal? (bencode-decode-bytes (bencode-encode v)) v))

(deftest bencode-encode-test
  (testing "encode"
    (testing "strings"
      (is (= "4:spam" (bencode-encode-string "spam")))
      (is (= "0:" (bencode-encode-string "")))
      ;; the length prefix counts bytes, not characters ("é" is 2 bytes)
      (is (= "6:héllo" (bencode-encode-string "héllo")) "utf-8 length is in bytes"))
    (testing "integers"
      (is (= "i42e" (bencode-encode-string 42)))
      (is (= "i0e" (bencode-encode-string 0)))
      (is (= "i-7e" (bencode-encode-string -7))))
    (testing "lists"
      (is (= "l4:spam4:eggse" (bencode-encode-string (list "spam" "eggs"))))
      (is (= "le" (bencode-encode-string '()))))
    (testing "dicts"
      (is (= "d3:cow3:moo4:spam4:eggse"
           (bencode-encode-string (hash "cow" "moo" "spam" "eggs"))))
      (is (= "de" (bencode-encode-string (hash))))
      ;; keys must be emitted in raw byte (here ASCII) order regardless of insert order
      (is (= "d3:aaa1:23:mmm1:33:zzz1:1e"
           (bencode-encode-string (hash "zzz" "1" "aaa" "2" "mmm" "3")))
        "keys are sorted"))
    (testing "nesting"
      (is (= "d1:ali1ei2ee1:bd1:c1:dee"
           (bencode-encode-string (hash "a" (list 1 2) "b" (hash "c" "d"))))))))

(deftest bencode-decode-test
  (testing "decode"
    (testing "strings"
      (is (= "spam" (dec "4:spam")))
      (is (= "" (dec "0:")))
      (is (= "héllo" (dec "6:héllo"))))
    (testing "integers"
      (is (= 42 (dec "i42e")))
      (is (= -7 (dec "i-7e"))))
    (testing "lists"
      (is (= (list "spam" "eggs") (dec "l4:spam4:eggse")))
      (is (= '() (dec "le"))))
    (testing "dicts"
      (is (= (hash "cow" "moo" "spam" "eggs") (dec "d3:cow3:moo4:spam4:eggse"))))))

(deftest bencode-round-trip-test
  (testing "round trips"
    (is (round-trips? "hello world") "string")
    (is (round-trips? -123456) "integer")
    (is (round-trips? (list "a" 1 "b" 2)) "list")
    (is (round-trips? (hash "x" (list 1 2 3) "y" (hash "z" "w"))) "nested")
    (testing "representative nREPL frames"
      (is (round-trips? (hash "op" "eval" "id" "1" "session" "abc-123" "code" "(+ 1 2)"))
        "eval request")
      (is (round-trips?
           (hash "id" "1" "session" "abc-123" "value" "3" "status" (list "done")))
        "eval response"))
    ;; a multi-KB body exercises the bytevector accumulator in the decoder
    (is (round-trips?
         (apply string-append (map (lambda (_) "0123456789abcdef") (range 0 512))))
      "multi-KB string")))

(deftest bencode-malformed-input-test
  (testing "malformed input is rejected, not panicked"
    (is (thrown? (dec "")) "empty input")
    (is (thrown? (dec "x")) "bad type prefix")
    (is (thrown? (dec "i42")) "unterminated int")
    (is (thrown? (dec "ie")) "empty int")
    (is (thrown? (dec "5:abc")) "truncated string")
    (is (thrown? (dec "l4:spam")) "unterminated list")
    (is (thrown? (dec "d3:cow3:moo")) "unterminated dict")
    (is (thrown? (dec "di1e3:fooe")) "non-string dict key")))
