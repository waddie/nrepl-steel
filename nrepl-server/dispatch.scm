;; dispatch.scm — op routing and nREPL response shaping.
;;
;; dispatch : registry, request-dict -> (list response-dict ...)
;;
;; Pure with respect to I/O: a handler turns one request into the ordered list of
;; response dicts that answer it. The server loop (Phase 6) writes them through the
;; connection's mutex-guarded writer. Every request is answered by at least one
;; response, and the final response for a request always carries "done" in its status.
;;
;; Response field conventions (matched against nrepl.hx's nrepl-rs):
;;   id           echoed from the request
;;   session      echoed when the request carried one
;;   status       list of tokens; "done" terminates; "error"/"eval-error" = failure;
;;                "unknown-op" = unsupported op; "interrupted"/"session-idle" = interrupt
;;   value        one per evaluated form (client accumulates)
;;   out / err    captured stdout / stderr (batched — one of each per eval)
;;   ex / root-ex exception text on eval error
;;   new-session  clone result; sessions: ls-sessions result; ops/versions: describe

(require "session.scm")

(provide dispatch server-ops)

;; The ops this server advertises (and answers). Anything else -> unknown-op.
(define server-ops
  (list "clone" "describe" "eval" "load-file" "close" "ls-sessions" "interrupt"
    "completions"
    "lookup"
    "info"))

(define (dispatch reg req)
  (define op (hash-try-get req "op"))
  (cond
    [(equal? op "clone") (op-clone reg req)]
    [(equal? op "describe") (op-describe reg req)]
    [(equal? op "eval") (op-eval reg req)]
    [(equal? op "load-file") (op-load-file reg req)]
    [(equal? op "close") (op-close reg req)]
    [(equal? op "ls-sessions") (op-ls-sessions reg req)]
    [(equal? op "interrupt") (op-interrupt reg req)]
    [(equal? op "completions") (op-completions reg req)]
    ;; `lookup` (nREPL) and `info` (cider) are the same symbol-metadata query.
    [(equal? op "lookup") (op-lookup reg req)]
    [(equal? op "info") (op-lookup reg req)]
    [else (op-unknown reg req)]))

;; --- response construction -------------------------------------------------

;; Build a response dict from `fields`, echoing id (and session when the request had
;; one) so the client can route and attribute it.
(define (respond req fields)
  (define id (hash-try-get req "id"))
  (define with-id (if id (hash-insert fields "id" id) fields))
  (define session (hash-try-get req "session"))
  (if session (hash-insert with-id "session" session) with-id))

(define (done-status . tokens) (append tokens (list "done")))

;; --- ops -------------------------------------------------------------------

(define (op-clone reg req)
  (define new-id (registry-clone! reg))
  (list (respond req (hash "new-session" new-id "status" (done-status)))))

;; Clojure-style unknown-op uses status [error unknown-op done].
(define (op-unknown reg req)
  (list (respond req (hash "status" (done-status "error" "unknown-op")))))

(define describe-ops
  (hash "clone" (hash) "describe" (hash) "eval" (hash)
    "load-file"
    (hash)
    "close"
    (hash)
    "ls-sessions"
    (hash)
    "interrupt"
    (hash)
    "completions"
    (hash)
    "lookup"
    (hash)
    "info"
    (hash)))

;; versions: a map of name -> {string -> string} (Q4 — the client only needs the
;; type to fit; values are informational).
(define describe-versions
  (hash "nrepl-steel" (hash "version-string" "0.2.0")
    "steel"
    (hash "version-string" "0.8.2")))

(define (op-describe reg req)
  (list (respond req (hash "ops" describe-ops
                      "versions"
                      describe-versions
                      "status"
                      (done-status)))))

;; Shared core for eval and load-file: validate session + payload, then run `code` in
;; the session and shape the result. `missing-token` names the absent-payload error so
;; eval reports "no-code" and load-file reports "no-file".
(define (run-code-op reg req code missing-token)
  (define session (hash-try-get req "session"))
  (cond
    [(not session) (list (respond req (hash "status" (done-status "error" "no-session"))))]
    [(not code) (list (respond req (hash "status" (done-status "error" missing-token))))]
    [(not (registry-get reg session))
      (list (respond req (hash "status" (done-status "error" "unknown-session"))))]
    [else (eval-responses req (registry-eval reg session code))]))

(define (op-eval reg req)
  (run-code-op reg req (hash-try-get req "code") "no-code"))

;; load-file: per the nREPL spec the `file` field carries the file *contents* (not a
;; path), evaluated like `code`. Optional `file-path`/`file-name` are diagnostic
;; metadata only and are ignored in stage one. Multiple forms in the file yield one
;; `value` per form, exactly as eval does.
(define (op-load-file reg req)
  (run-code-op reg req (hash-try-get req "file") "no-file"))

;; Turn an evaluator result hash into the ordered response list: batched out, batched
;; err, one value per form, then a terminating status (eval-error when it raised).
(define (eval-responses req r)
  (define out (hash-ref r 'out))
  (define err (hash-ref r 'err))
  (append
    (if (> (string-length out) 0) (list (respond req (hash "out" out))) '())
    (if (> (string-length err) 0) (list (respond req (hash "err" err))) '())
    (map (lambda (v) (respond req (hash "value" v))) (hash-ref r 'value))
    (list
      (if (equal? (hash-ref r 'status) 'error)
        (respond req (hash "ex" (hash-ref r 'ex)
                      "root-ex"
                      (hash-ref r 'ex)
                      "status"
                      (done-status "eval-error")))
        (respond req (hash "status" (done-status)))))))

(define (op-close reg req)
  (define session (hash-try-get req "session"))
  (cond
    [(not session) (list (respond req (hash "status" (done-status "error" "no-session"))))]
    [(registry-close! reg session)
      (list (respond req (hash "status" (done-status "session-closed"))))]
    [else (list (respond req (hash "status" (done-status "error" "unknown-session"))))]))

(define (op-ls-sessions reg req)
  (list (respond req (hash "sessions" (registry-ids reg) "status" (done-status)))))

;; completions: enumerate the session engine's readable globals matching `prefix`.
;; Response field `completions` is a list of dicts, each with `candidate` (the name)
;; and `type` ("function"/"value"). Steel has no namespaces, so `ns` is omitted.
;; An absent/empty prefix lists everything bound in the session.
(define (op-completions reg req)
  (define session (hash-try-get req "session"))
  (define prefix (or (hash-try-get req "prefix") ""))
  (cond
    [(not session) (list (respond req (hash "status" (done-status "error" "no-session"))))]
    [(not (registry-get reg session))
      (list (respond req (hash "status" (done-status "error" "unknown-session"))))]
    [else
      (define candidates
        (map (lambda (pair) (hash "candidate" (car pair) "type" (car (cdr pair))))
          (registry-complete reg session prefix)))
      (list (respond req (hash "completions" candidates "status" (done-status))))]))

;; lookup/info: symbol metadata for `sym` in the session. The backend returns a
;; string->string hash (name/type/doc + arglists-str/arglists) ready to be the
;; response `info` field; an unbound symbol yields the `no-info` status token.
(define (op-lookup reg req)
  (define session (hash-try-get req "session"))
  (define sym (hash-try-get req "sym"))
  (cond
    [(not session) (list (respond req (hash "status" (done-status "error" "no-session"))))]
    [(not sym) (list (respond req (hash "status" (done-status "error" "no-symbol"))))]
    [(not (registry-get reg session))
      (list (respond req (hash "status" (done-status "error" "unknown-session"))))]
    [else
      (define info (registry-info reg session sym))
      (if info
        (list (respond req (hash "info" info "status" (done-status))))
        (list (respond req (hash "status" (done-status "no-info")))))]))

;; Interrupt is queued-only/best-effort (Phase 1 finding). In the synchronous registry
;; there is no in-flight eval to cancel, so a known session is reported idle. The
;; queued-cancellation path lands with the server loop's per-session queue (Phase 6).
(define (op-interrupt reg req)
  (define session (hash-try-get req "session"))
  (cond
    [(and session (not (registry-get reg session)))
      (list (respond req (hash "status" (done-status "error" "unknown-session"))))]
    [else (list (respond req (hash "status" (done-status "session-idle"))))]))
