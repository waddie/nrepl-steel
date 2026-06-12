;; bencode.scm — bencode codec for nREPL, over byte ports.
;;
;; Bencode grammar (the nREPL transport):
;;   byte-string : <len>:<raw-bytes>        e.g.  4:spam
;;   integer     : i<digits>e               e.g.  i42e   i-7e
;;   list        : l <values...> e          e.g.  l4:spam4:eggse
;;   dict        : d <str-key><value>... e   keys sorted by raw byte order
;;
;; Value model (implementation-plan.md Q2):
;;   bencode string <-> Steel string  (UTF-8; the length prefix is the BYTE count)
;;   bencode integer <-> Steel integer
;;   bencode list    <-> Steel list
;;   bencode dict    <-> Steel hash map with string keys
;; Encoding dispatches on Steel type; decoding dispatches on the prefix byte, so no
;; tagging is needed. Binary (non-UTF-8) byte-strings are out of scope — nREPL is text.
;;
;; Decode reads exactly one complete value from an input byte port and leaves the port
;; positioned immediately after it, so transport can read frames back to back.

(require "steel/result")

(provide bencode-encode ; value -> bytevector
  bencode-encode-string ; value -> bencode bytes, but as a Steel string (tests)
  bencode-decode ; input-byte-port -> value   (one frame)
  bencode-decode-bytes) ; bytevector -> value        (convenience/tests)

;; Defensive cap on a single string's declared length (cf. nrepl-rs: 100 MB), so a
;; bogus length prefix can't drive an unbounded allocation.
(define MAX-STRING-LENGTH (* 100 1024 1024))

;; ASCII byte constants for the framing characters.
(define BYTE-i 105)
(define BYTE-l 108)
(define BYTE-d 100)
(define BYTE-e 101)
(define BYTE-colon 58)
(define BYTE-0 48)
(define BYTE-9 57)

;; --- encoding --------------------------------------------------------------

(define (bencode-encode val)
  (define op (open-output-bytevector))
  (enc val op)
  (get-output-bytevector op))

(define (bencode-encode-string val)
  (bytes->string/utf8 (bencode-encode val)))

(define (enc val op)
  (cond
    [(int? val) (enc-int val op)]
    [(string? val) (enc-string val op)]
    [(hash? val) (enc-dict val op)]
    [(list? val) (enc-list val op)]
    [else (error "bencode-encode: unsupported value" val)]))

;; Write a Steel string's UTF-8 bytes verbatim (used for the ASCII framing digits too).
(define (enc-raw s op)
  (write-bytes (string->bytes s) op))

(define (enc-int n op)
  (write-byte BYTE-i op)
  (enc-raw (number->string n) op)
  (write-byte BYTE-e op))

(define (enc-string s op)
  (define b (string->bytes s))
  (enc-raw (number->string (bytes-length b)) op)
  (write-byte BYTE-colon op)
  (write-bytes b op))

(define (enc-list xs op)
  (write-byte BYTE-l op)
  (for-each (lambda (x) (enc x op)) xs)
  (write-byte BYTE-e op))

(define (enc-dict h op)
  (write-byte BYTE-d op)
  ;; Spec: keys sorted by raw byte order. nREPL keys are ASCII, for which string<?
  ;; is byte order. Keys must be strings.
  (for-each (lambda (k)
             (unless (string? k) (error "bencode-encode: dict key not a string" k))
             (enc-string k op)
             (enc (hash-ref h k) op))
    (sort (hash-keys->list h) string<?))
  (write-byte BYTE-e op))

;; --- decoding --------------------------------------------------------------

(define (bencode-decode-bytes bv)
  (bencode-decode (open-input-bytevector bv)))

(define (bencode-decode ip)
  (define b (peek-byte ip))
  (cond
    [(eof-object? b) (error "bencode-decode: unexpected end of input")]
    [(= b BYTE-i) (dec-int ip)]
    [(= b BYTE-l) (dec-list ip)]
    [(= b BYTE-d) (dec-dict ip)]
    [(digit-byte? b) (dec-string ip)]
    [else (error "bencode-decode: invalid prefix byte" b)]))

(define (digit-byte? b) (and (>= b BYTE-0) (<= b BYTE-9)))

;; bytes collected as a reversed list -> Steel string
(define (rev-bytes->string acc) (bytes->string/utf8 (list->bytes (reverse acc))))

(define (dec-int ip)
  (read-byte ip) ; consume 'i'
  (let loop ([acc '()])
    (define b (read-byte ip))
    (cond
      [(eof-object? b) (error "bencode-decode: unterminated integer")]
      [(= b BYTE-e)
        (when (null? acc) (error "bencode-decode: empty integer"))
        (define n (string->number (rev-bytes->string acc)))
        (unless (int? n) (error "bencode-decode: malformed integer"))
        n]
      [else (loop (cons b acc))])))

(define (dec-string ip)
  (let loop ([acc '()])
    (define b (read-byte ip))
    (cond
      [(eof-object? b) (error "bencode-decode: unterminated string length")]
      [(= b BYTE-colon) (read-n-bytes->string ip (string->number (rev-bytes->string acc)))]
      [(digit-byte? b) (loop (cons b acc))]
      [else (error "bencode-decode: invalid byte in string length" b)])))

(define (read-n-bytes->string ip n)
  (when (> n MAX-STRING-LENGTH) (error "bencode-decode: string length exceeds cap" n))
  (let loop ([i 0] [acc '()])
    (if (= i n)
      (rev-bytes->string acc)
      (let ([b (read-byte ip)])
        (if (eof-object? b)
          (error "bencode-decode: truncated string body")
          (loop (+ i 1) (cons b acc)))))))

(define (dec-list ip)
  (read-byte ip) ; consume 'l'
  (let loop ([acc '()])
    (define b (peek-byte ip))
    (cond
      [(eof-object? b) (error "bencode-decode: unterminated list")]
      [(= b BYTE-e) (read-byte ip) (reverse acc)]
      [else (loop (cons (bencode-decode ip) acc))])))

(define (dec-dict ip)
  (read-byte ip) ; consume 'd'
  (let loop ([h (hash)])
    (define b (peek-byte ip))
    (cond
      [(eof-object? b) (error "bencode-decode: unterminated dict")]
      [(= b BYTE-e) (read-byte ip) h]
      [else
        (define k (bencode-decode ip))
        (unless (string? k) (error "bencode-decode: dict key not a string" k))
        (define v (bencode-decode ip))
        (loop (hash-insert h k v))])))
