;; nrepl-steel.scm — start the pure-Scheme nREPL server and keep it alive.
;;
;;   steel nrepl-steel.scm [host:port]      (default 127.0.0.1:7888)
;;
;; Then point an nREPL client at it, e.g. nrepl.hx:  :nrepl-connect localhost:7888
;;
;; The server serves each connection on its own native thread; this main thread just
;; parks so the process stays up. Ctrl-C to stop.
;;
;; NOTE: drive this from a SEPARATE process. A client sharing this Steel runtime can
;; deadlock with the server on a tight request/response loop (in-process scheduling —
;; see test/server-test.scm). An external client is unaffected.

(require "nrepl-server/server.scm")
(require-builtin steel/time)

(define (addr-from-args)
  (define args (command-line))
  ;; (steel nrepl-steel.scm [addr]) -> the 3rd element, if present
  (if (>= (length args) 3) (list-ref args 2) "127.0.0.1:7888"))

(define addr (addr-from-args))
(define server (server-start! (make-server addr)))
(displayln (string-append "nREPL server listening on " addr))
(flush-output-port (current-output-port))

;; Park the main thread so the accept loop keeps running.
(let loop ()
  (time/sleep-ms 1000)
  (loop))
