(define package-name 'nrepl-steel)
(define version "0.1.0")

;; Pure-Scheme nREPL server for Steel. No external dependencies.
(define dependencies '())

;; Entrypoint — installed to $STEEL_HOME/bin/nrepl-steel
(define entrypoint '(#:name "nrepl-steel" #:path "bin/nrepl-steel.scm"))
