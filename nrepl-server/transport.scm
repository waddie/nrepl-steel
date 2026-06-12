;; transport.scm — nREPL message framing on a byte stream.
;;
;; A thin layer over bencode: move whole nREPL messages (bencode dicts) in and out of
;; a byte port. Knows nothing about ops, sessions, or sockets — it just frames dicts.
;; The same code works over an in-memory bytevector port (tests) or a TCP stream
;; (tcp-stream-buffered-reader / tcp-stream-writer).

(require "bencode.scm")

(provide read-message ; in-byte-port -> dict | 'eof
  write-message ; out-byte-port, dict -> void   (unsynchronised)
  make-writer) ; out-byte-port -> (dict -> void), mutex-guarded

;; Read one nREPL message from `in`. Returns the message (a hash) or the symbol 'eof
;; when the stream is cleanly exhausted. On a blocking stream (a real socket) this
;; blocks until a full frame or EOF arrives, which suits the thread-per-connection
;; model. A frame that is not a dict is a protocol error.
(define (read-message in)
  (if (eof-object? (peek-byte in))
    'eof
    (let ([msg (bencode-decode in)])
      (unless (hash? msg) (error "transport: message is not a dict" msg))
      msg)))

;; Encode and write one message as a single frame, then flush. NOT synchronised — use
;; make-writer when more than one thread may write to the same stream.
(define (write-message out msg)
  (unless (hash? msg) (error "transport: message is not a dict" msg))
  (write-bytes (bencode-encode msg) out)
  (flush-output-port out))

;; Wrap an output stream so concurrent senders (multiple sessions sharing one
;; connection) cannot interleave mid-frame. Returns a one-arg procedure that writes a
;; message under a mutex. One writer per connection.
;; NB: lock-acquire! returns a guard; lock-release! takes that guard (not the mutex).
(define (make-writer out)
  (define m (mutex))
  (lambda (msg)
    (define guard (lock-acquire! m))
    (dynamic-wind
      (lambda () void)
      (lambda () (write-message out msg))
      (lambda () (lock-release! guard)))))
