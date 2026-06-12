;; Tests for nrepl-server/dispatch.scm
;; Feeds synthetic request dicts through dispatch and asserts the response dicts.
;; Uses the real registry+evaluator (in-process, fast) so this also integration-tests
;; the dispatch -> session -> evaluator path at the dict level. No socket.
(require "harness.scm")
(require "../nrepl-server/evaluator.scm")
(require "../nrepl-server/session.scm")
(require "../nrepl-server/dispatch.scm")

(define reg (make-registry (make-standalone-evaluator)))

;; --- helpers ---------------------------------------------------------------
(define (last-of xs) (if (null? (cdr xs)) (car xs) (last-of (cdr xs))))
(define (terminator resps) (last-of resps))
(define (status resps) (hash-ref (terminator resps) "status"))
;; collect the value of `key` from every response that carries it
(define (collect resps key)
  (filter (lambda (x) (not (equal? x 'none)))
    (map (lambda (r) (if (hash-contains? r key) (hash-ref r key) 'none)) resps)))
(define (has-token? resps tok) (and (member tok (status resps)) #t))

;; --- clone -----------------------------------------------------------------
(define clone-resps (dispatch reg (hash "op" "clone" "id" "1")))
(check-equal? "clone: one response" (length clone-resps) 1)
(check-equal? "clone: echoes id" (hash-ref (car clone-resps) "id") "1")
(check-true "clone: new-session is a string"
  (string? (hash-ref (car clone-resps) "new-session")))
(check-true "clone: done" (has-token? clone-resps "done"))

(define sid (hash-ref (car clone-resps) "new-session"))

;; --- describe --------------------------------------------------------------
(define desc (dispatch reg (hash "op" "describe" "id" "d1")))
(check-true "describe: advertises all server ops"
  (let ([ops (hash-ref (car desc) "ops")])
    (and (hash-contains? ops "clone") (hash-contains? ops "eval")
      (hash-contains? ops "describe")
      (hash-contains? ops "close")
      (hash-contains? ops "ls-sessions")
      (hash-contains? ops "interrupt"))))
(check-true "describe: advertises load-file"
  (hash-contains? (hash-ref (car desc) "ops") "load-file"))
(check-true "describe: has versions" (hash-contains? (car desc) "versions"))
(check-true "describe: done" (has-token? desc "done"))

;; --- eval: value -----------------------------------------------------------
(define ev (dispatch reg (hash "op" "eval" "id" "2" "session" sid "code" "(+ 1 2)")))
(check-equal? "eval: value present" (collect ev "value") (list "3"))
(check-equal? "eval: echoes session" (hash-ref (terminator ev) "session") sid)
(check-true "eval: done" (has-token? ev "done"))
(check-true "eval: not an error" (not (has-token? ev "eval-error")))

;; --- eval: output ----------------------------------------------------------
(define evo (dispatch reg (hash "op" "eval" "id" "3" "session" sid "code" "(display \"hi\")")))
(check-equal? "eval: out captured" (collect evo "out") (list "hi"))

;; --- eval: error -----------------------------------------------------------
(define eve (dispatch reg (hash "op" "eval" "id" "4" "session" sid "code" "(car '())")))
(check-true "eval error: eval-error token" (has-token? eve "eval-error"))
(check-true "eval error: ex present"
  (string? (hash-ref (terminator eve) "ex")))
(check-equal? "eval error: no value" (collect eve "value") '())

;; --- eval: missing/unknown session ----------------------------------------
(check-true "eval: no session -> error"
  (has-token? (dispatch reg (hash "op" "eval" "id" "5" "code" "1")) "error"))
(check-true "eval: unknown session -> error"
  (has-token? (dispatch reg (hash "op" "eval" "id" "6" "session" "nope" "code" "1"))
    "error"))

;; --- load-file -------------------------------------------------------------
;; `file` carries the file contents; multiple forms yield one value per form and
;; definitions persist in the session just like eval.
(define lf (dispatch reg (hash "op" "load-file" "id" "lf1" "session" sid
                          "file"
                          "(define lf-a 10)\n(+ lf-a 5)")))
(check-equal? "load-file: value of last form" (collect lf "value") (list "15"))
(check-true "load-file: done" (has-token? lf "done"))
(check-equal? "load-file: defs persist into a later eval"
  (collect (dispatch reg (hash "op" "eval" "id" "lf2" "session" sid "code" "lf-a")) "value")
  (list "10"))
(check-true "load-file: missing file -> error"
  (has-token? (dispatch reg (hash "op" "load-file" "id" "lf3" "session" sid)) "error"))
(check-true "load-file: unknown session -> error"
  (has-token? (dispatch reg (hash "op" "load-file" "id" "lf4" "session" "nope" "file" "1"))
    "error"))

;; --- ls-sessions -----------------------------------------------------------
(define ls (dispatch reg (hash "op" "ls-sessions" "id" "7")))
(check-true "ls-sessions: lists the open session"
  (and (member sid (hash-ref (car ls) "sessions")) #t))

;; --- interrupt (queued-only; idle in synchronous registry) -----------------
(check-true "interrupt: idle session"
  (has-token? (dispatch reg (hash "op" "interrupt" "id" "8" "session" sid))
    "session-idle"))
(check-true "interrupt: unknown session -> error"
  (has-token? (dispatch reg (hash "op" "interrupt" "id" "8b" "session" "nope"))
    "error"))

;; --- close ----------------------------------------------------------------
(check-true "close: done" (has-token? (dispatch reg (hash "op" "close" "id" "9" "session" sid))
                           "done"))
(check-true "close: session gone from ls"
  (not (member sid (hash-ref (car (dispatch reg (hash "op" "ls-sessions" "id" "10")))
                    "sessions"))))

;; --- unknown op ------------------------------------------------------------
(define unk (dispatch reg (hash "op" "frobnicate" "id" "11")))
(check-true "unknown-op: unknown-op token" (has-token? unk "unknown-op"))
(check-true "unknown-op: error token" (has-token? unk "error"))
(check-equal? "unknown-op: echoes id" (hash-ref (car unk) "id") "11")
