;; cli.scm — entry-point argument parsing and the .nrepl-port convention.
;;
;; Shared by the two entry points: nrepl-steel.scm (run from a checkout) and
;; bin/nrepl-steel.scm (installed to $STEEL_HOME/bin by forge). They differ only in
;; their require prefix, so the argv shape and the port-file behaviour live here rather
;; than being duplicated and drifting apart.
;;
;; This is deliberately NOT part of server.scm: server-start! is called by the test
;; suite, which must never drop a .nrepl-port into the repo root. Writing the file is an
;; entry-point concern, so only an entry point does it.
;;
;; The .nrepl-port file is how nREPL tooling discovers a running server without being
;; told the port (clients search the cwd and its ancestors). Servers that skip it are
;; unreachable to discovery-based clients such as nautilos and CIDER.

(require-builtin steel/filesystem)

(provide PORT-FILE
  DEFAULT-ADDR
  cli-addr
  cli-write-port-file?
  addr-port
  write-port-file!)

(define PORT-FILE ".nrepl-port")
(define DEFAULT-ADDR "127.0.0.1:7888")

;; Everything after the script name: (steel <script> args...) -> args
(define (script-args argv)
  (if (>= (length argv) 3) (list-tail argv 2) '()))

;; The listen address: the first non-flag argument, else the default.
(define (cli-addr argv)
  (define positional
    (filter (lambda (a) (not (starts-with? a "--"))) (script-args argv)))
  (if (null? positional) DEFAULT-ADDR (car positional)))

(define (cli-write-port-file? argv)
  (not (if (member "--no-port-file" (script-args argv)) #t #f)))

;; The port is the last colon-separated field, which also holds for a bracketed IPv6
;; host ("[::1]:7888" -> "7888").
(define (addr-port a) (last (split-many a ":")))

;; Write the port where discovery-based clients look. Call this only AFTER a successful
;; bind, so a failed start never advertises a server that is not listening.
;;
;; Best-effort: an unwritable cwd is reported but must not take down a server that has
;; already bound. Overwrites any existing file — a leftover from a killed server is
;; exactly what wants replacing, and Steel has no signal handler with which to have
;; removed it.
(define (write-port-file! addr)
  (with-handler
    (lambda (e)
      (displayln
        (string-append "warning: could not write " PORT-FILE ": " (value->string e))))
    (let ([p (open-output-file PORT-FILE)])
      (write-string (addr-port addr) p)
      (close-output-port p))))
