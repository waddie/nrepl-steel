;; Tests for steel/nrepl-server/bencode.scm
(require "harness.scm")
(require "../steel/nrepl-server/bencode.scm")

;; --- encode: spec vectors --------------------------------------------------
(check-equal? "enc string" (bencode-encode-string "spam") "4:spam")
(check-equal? "enc empty string" (bencode-encode-string "") "0:")
(check-equal? "enc int" (bencode-encode-string 42) "i42e")
(check-equal? "enc int zero" (bencode-encode-string 0) "i0e")
(check-equal? "enc int negative" (bencode-encode-string -7) "i-7e")
(check-equal? "enc list" (bencode-encode-string (list "spam" "eggs")) "l4:spam4:eggse")
(check-equal? "enc empty list" (bencode-encode-string '()) "le")
(check-equal? "enc dict"
  (bencode-encode-string (hash "cow" "moo" "spam" "eggs"))
  "d3:cow3:moo4:spam4:eggse")
(check-equal? "enc empty dict" (bencode-encode-string (hash)) "de")

;; dict keys must be emitted in raw byte (here ASCII) order regardless of insert order
(check-equal? "enc dict sorts keys"
  (bencode-encode-string (hash "zzz" "1" "aaa" "2" "mmm" "3"))
  "d3:aaa1:23:mmm1:33:zzz1:1e")

;; UTF-8: the length prefix counts bytes, not characters ("é" is 2 bytes)
(check-equal? "enc utf8 byte length" (bencode-encode-string "héllo") "6:héllo")

;; nested
(check-equal? "enc nested dict/list"
  (bencode-encode-string (hash "a" (list 1 2) "b" (hash "c" "d")))
  "d1:ali1ei2ee1:bd1:c1:dee")

;; --- decode ----------------------------------------------------------------
(check-equal? "dec string" (bencode-decode-bytes (string->bytes "4:spam")) "spam")
(check-equal? "dec empty string" (bencode-decode-bytes (string->bytes "0:")) "")
(check-equal? "dec int" (bencode-decode-bytes (string->bytes "i42e")) 42)
(check-equal? "dec int neg" (bencode-decode-bytes (string->bytes "i-7e")) -7)
(check-equal? "dec list" (bencode-decode-bytes (string->bytes "l4:spam4:eggse"))
  (list "spam" "eggs"))
(check-equal? "dec empty list" (bencode-decode-bytes (string->bytes "le")) '())
(check-equal? "dec dict" (bencode-decode-bytes (string->bytes "d3:cow3:moo4:spam4:eggse"))
  (hash "cow" "moo" "spam" "eggs"))
(check-equal? "dec utf8" (bencode-decode-bytes (string->bytes "6:héllo")) "héllo")

;; --- round trips -----------------------------------------------------------
(define (round-trips? v) (equal? (bencode-decode-bytes (bencode-encode v)) v))

(check-true "rt string" (round-trips? "hello world"))
(check-true "rt int" (round-trips? -123456))
(check-true "rt list" (round-trips? (list "a" 1 "b" 2)))
(check-true "rt nested" (round-trips? (hash "x" (list 1 2 3) "y" (hash "z" "w"))))
;; a representative nREPL eval request
(check-true "rt nrepl eval req"
  (round-trips? (hash "op" "eval" "id" "1" "session" "abc-123" "code" "(+ 1 2)")))
;; a representative nREPL eval response with a list status
(check-true "rt nrepl eval resp"
  (round-trips? (hash "id" "1" "session" "abc-123" "value" "3" "status" (list "done"))))

;; --- malformed input is rejected, not panicked -----------------------------
(check-err? "dec empty input" (bencode-decode-bytes (string->bytes "")))
(check-err? "dec bad prefix" (bencode-decode-bytes (string->bytes "x")))
(check-err? "dec unterminated int" (bencode-decode-bytes (string->bytes "i42")))
(check-err? "dec empty int" (bencode-decode-bytes (string->bytes "ie")))
(check-err? "dec truncated string" (bencode-decode-bytes (string->bytes "5:abc")))
(check-err? "dec unterminated list" (bencode-decode-bytes (string->bytes "l4:spam")))
(check-err? "dec unterminated dict" (bencode-decode-bytes (string->bytes "d3:cow3:moo")))
(check-err? "dec non-string key" (bencode-decode-bytes (string->bytes "di1e3:fooe")))
