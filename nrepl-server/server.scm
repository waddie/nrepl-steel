;; server.scm — TCP accept loop and per-connection serving.
;;
;; Concurrency model (stage one): one shared registry; the accept loop spawns one
;; native thread per connection. A connection thread reads requests, dispatches each,
;; and writes the response list through a per-connection mutex-guarded writer. Requests
;; on a single connection are therefore serialized by that one thread — which is exactly
;; nREPL's "requests within a session are serialized", since a client owns its sessions
;; on its own connection. Different connections (and thus different sessions, which are
;; isolated engines) run concurrently. LIMITATION: driving the SAME session id
;; concurrently from two connections is unsupported (no per-session lock — the
;; worker-thread/channel model was dropped after the interrupt findings, see
;; spike-interrupt.md). For a single editor client this never arises.
;;
;; Two socket facts forced this shape (Steel 0.8.2, macOS):
;;   - tcp-listener-local-addr is NOT registered in steel/tcp, so an ephemeral :0 port
;;     can't be discovered — the server binds an explicit address.
;;   - a non-blocking listener yields non-blocking accepted streams whose reads return
;;     eof immediately, so we keep the listener BLOCKING and stop the accept loop by
;;     self-connecting (server-stop!) to wake the blocked tcp-accept.

(require "transport.scm")
(require "dispatch.scm")
(require "session.scm")
(require "evaluator.scm")
(require-builtin steel/tcp)

(provide make-server
  server-start!
  server-stop!
  server-addr
  server-registry
  normalize-addr
  serve-loop
  server-error-response)

(struct Server (addr listener registry running) #:mutable)

;; "localhost:7888" -> "127.0.0.1:7888".
;;
;; tcp-listen is TcpListener::bind, which binds the FIRST address the string resolves to
;; and stops. On macOS "localhost" resolves ::1 ahead of 127.0.0.1, so "localhost:7888"
;; listens on IPv6 loopback ONLY and every IPv4 client gets connection-refused. Clients
;; that connect by hostname survive it (they try each resolved address), which is why
;; nrepl.hx never noticed; clients that connect to a literal 127.0.0.1, such as nautilos,
;; cannot reach the server at all.
;;
;; It also breaks .nrepl-port, which carries a port and no host: every client reading it
;; assumes IPv4 loopback, so an IPv6-only server advertises an address it is not
;; listening on. Binding 127.0.0.1 for "localhost" keeps the file honest and matches
;; what Clojure's nREPL binds by default. An explicitly bracketed host ("[::1]:7888")
;; contains no "localhost:" prefix and is passed through untouched, so asking for IPv6
;; still works.
(define (normalize-addr a)
  (if (starts-with? a "localhost:")
    (string-append "127.0.0.1:" (trim-start-matches a "localhost:"))
    a))

(define (make-server addr)
  (Server (normalize-addr addr) #f (make-registry (make-native-evaluator)) #f))

(define (server-addr s) (Server-addr s))
(define (server-registry s) (Server-registry s))

;; Bind, mark running, and run the accept loop on its own thread. Returns the server.
;; tcp-listen raises if the address is in use — let that propagate to the caller.
(define (server-start! server)
  (set-Server-listener! server (tcp-listen (Server-addr server)))
  (set-Server-running! server #t)
  (spawn-native-thread (lambda () (accept-loop server)))
  server)

;; Stop accepting: clear the flag, then self-connect to wake the blocked tcp-accept so
;; the loop observes the flag and returns. Live connection threads end when their
;; clients disconnect (read -> eof). steel/tcp has no listener-close primitive
;; (tcp-shutdown! is stream-only), so the best we can do is drop our reference: the
;; underlying socket closes when the listener value is reclaimed, so the port may stay
;; bound briefly after stop.
(define (server-stop! server)
  (set-Server-running! server #f)
  (with-handler (lambda (e) void)
    (let ([c (tcp-connect (Server-addr server))]) (tcp-shutdown! c)))
  (set-Server-listener! server #f)
  void)

(define (accept-loop server)
  (when (Server-running server)
    (define s (with-handler (lambda (e) #f) (tcp-accept (Server-listener server))))
    (cond
      [(not s) (accept-loop server)] ; transient accept error -> retry
      [(not (Server-running server)) ; the stop wakeup socket
        (with-handler (lambda (e) void) (tcp-shutdown! s))]
      [else
        (spawn-native-thread
          (lambda () (serve-connection s (Server-registry server))))
        (accept-loop server)])))

;; Serve one connection until the client disconnects or sends an unframeable byte
;; stream (a bencode desync can't be resynchronised, so we drop the connection).
;;
;; serve-loop is wrapped so that ANY error ending the connection — most importantly a
;; broken-pipe write to a client that has gone away mid-exchange — terminates this
;; thread cleanly (shut the socket, return) instead of escaping as an uncaught error.
;; An uncaught error here leaves the native thread lingering, and a lingering connection
;; thread can starve the next connection's I/O (Steel 0.8.2 native-thread scheduling —
;; see spike-server-threading.md). Catching it lets the thread exit promptly so the
;; server recovers immediately after an abrupt client disconnect.
(define (serve-connection stream registry)
  (define reader (tcp-stream-buffered-reader stream))
  (define write! (make-writer (tcp-stream-writer stream)))
  (with-handler (lambda (e) void) (serve-loop reader write! registry))
  (with-handler (lambda (e) void) (tcp-shutdown! stream)))

;; The read -> dispatch -> write loop, decoupled from the socket so it can be tested
;; over in-memory ports. `reader` is a byte input port; `write!` takes a response dict.
;; Reads requests until eof / a framing error, answering each.
(define (serve-loop reader write! registry)
  (define req (with-handler (lambda (e) 'frame-error) (read-message reader)))
  (cond
    [(equal? req 'eof) void]
    [(equal? req 'frame-error) void]
    [else
      ;; A handler bug must never take the connection down silently: report it as a
      ;; server-error response and keep serving.
      (with-handler (lambda (err) (write! (server-error-response req err)))
        (for-each write! (dispatch registry req)))
      (serve-loop reader write! registry)]))

;; Echo id and session (when the request carried them) so the client can route and
;; attribute the failure, mirroring dispatch's `respond`.
(define (server-error-response req err)
  (define id (and (hash? req) (hash-try-get req "id")))
  (define session (and (hash? req) (hash-try-get req "session")))
  (define base (hash "status" (list "error" "server-error" "done") "ex" (value->string err)))
  (define with-id (if id (hash-insert base "id" id) base))
  (if session (hash-insert with-id "session" session) with-id))
