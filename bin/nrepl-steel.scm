;; nrepl-steel entrypoint — installed by forge to $STEEL_HOME/bin/nrepl-steel
;;
;;   nrepl-steel [host:port]     (default 127.0.0.1:7888)

(require "nrepl-steel/steel/nrepl-server/server.scm")
(require-builtin steel/time)

(define addr (if (>= (length (command-line)) 3)
              (list-ref (command-line) 2)
              "127.0.0.1:7888"))

(server-start! (make-server addr))
(displayln (string-append "nREPL server listening on " addr))
(flush-output-port (current-output-port))

(let loop ()
  (time/sleep-ms 1000)
  (loop))
