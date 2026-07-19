;; nrepl-steel.scm — start the pure-Scheme nREPL server and keep it alive.
;;
;;   steel nrepl-steel.scm [host:port] [--no-port-file]   (default 127.0.0.1:7888)
;;
;; Then point an nREPL client at it, e.g. nrepl.hx:  :nrepl-connect localhost:7888
;;
;; On a successful bind the port is written to ./.nrepl-port, the convention nREPL
;; tooling uses to discover a running server without being told the port. Clients that
;; rely on it (nautilos, CIDER, and most jack-in tooling) cannot find the server at all
;; without it. Pass --no-port-file to suppress the write.
;;
;; The file is NOT removed on shutdown: Steel exposes no signal handler, so a Ctrl-C'd
;; server never runs cleanup and a stale .nrepl-port is left behind (the same thing a
;; kill -9'd Clojure nREPL does). A client that finds one gets connection-refused
;; against the dead port; starting a new server overwrites it.
;;
;; The server serves each connection on its own native thread; this main thread just
;; parks so the process stays up. Ctrl-C to stop.
;;
;; NOTE: drive this from a SEPARATE process. A client sharing this Steel runtime can
;; deadlock with the server on a tight request/response loop (in-process scheduling —
;; see test/server-test.scm). An external client is unaffected.

(require "nrepl-server/server.scm")
(require "nrepl-server/cli.scm")
(require-builtin steel/time)

(define addr (cli-addr (command-line)))

;; Bind first: server-start! raises if the address is in use, so a failed start never
;; leaves a .nrepl-port advertising a server that is not listening.
(define server (server-start! (make-server addr)))
(when (cli-write-port-file? (command-line)) (write-port-file! addr))
(displayln (string-append "nREPL server listening on " addr))
(flush-output-port (current-output-port))

;; Park the main thread so the accept loop keeps running.
(let loop ()
  (time/sleep-ms 1000)
  (loop))
