;; evaluator.scm — the evaluation seam.
;;
;; Evaluation (and symbol introspection) is a single indirection so the rest of the
;; server (bencode / transport / session / dispatch) never knows how code is actually
;; run. An Evaluator is five procedures:
;;
;;   init     : () -> state              ;; create a fresh isolated session backend
;;   eval     : state, code -> result    ;; run code, return a result hash (below)
;;   close    : state -> void            ;; tear the backend down
;;   complete : state, prefix -> pairs   ;; readable globals matching prefix:
;;                                        ;; a list of (name type) two-element lists
;;   info     : state, sym -> info|#f    ;; symbol metadata: a string->string hash
;;                                        ;; (name/type/doc + arglists*), or #f if unbound
;;
;; The backend is the native `nrepl-steel-engine` dylib: one Steel engine per session, owned
;; by Rust. steel-core's own (Engine::new)/run! values can't be introspected from a
;; dylib (EngineWrapper is pub(crate)) and the global symbol table needed for
;; completions has no Scheme-level accessor — so the dylib owns the engines and exposes
;; eval + globals + symbol-info over the FFI. A future Helix backend would swap in
;; init/eval/close/complete/info that marshal onto the editor loop; nothing else changes.
;;
;; A result hash (from `eval`) has:
;;   'status : 'ok | 'error
;;   'value  : list of rendered value strings (one per evaluated form; void results
;;             — definitions, side effects — are dropped)
;;   'out    : captured stdout (string, possibly "")
;;   'err    : captured stderr (string, possibly "")
;;   'ex     : exception text when 'status is 'error, else #f

;; The native session-engine backend. Installed in $STEEL_HOME/native as
;; libnrepl_steel_engine.{dylib,so,dll}; built from crates/nrepl-steel-engine (see build.sh).
(#%require-dylib "libnrepl_steel_engine"
  (only-in engine/new engine/eval engine/globals engine/symbol-info engine/close))

(provide Evaluator Evaluator? Evaluator-init Evaluator-eval Evaluator-close
  Evaluator-complete
  Evaluator-info
  make-native-evaluator)

(struct Evaluator (init eval close complete info))

;; --- native backend --------------------------------------------------------

;; engine/eval returns a string-keyed hash (FFI hashes use string keys). Translate it
;; into the seam's symbol-keyed result so dispatch is unchanged.
(define (native-result->seam h)
  (hash 'status
    (if (equal? (hash-ref h "status") "ok") 'ok 'error)
    'value
    (hash-ref h "values")
    'out
    (hash-ref h "out")
    'err
    (hash-ref h "err")
    'ex
    (let ([e (hash-ref h "ex")]) (if (string? e) e #f))))

(define (make-native-evaluator)
  (Evaluator
    engine/new
    (lambda (e code) (native-result->seam (engine/eval e code)))
    engine/close
    ;; complete: the readable globals matching `prefix`, as (name type) pairs.
    engine/globals
    ;; info: a string->string metadata hash, or #f when the symbol is unbound.
    engine/symbol-info))
