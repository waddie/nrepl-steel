;; Tests for nrepl-server/server.scm — the connection serve loop.
;;
;; This drives `serve-loop` over IN-MEMORY byte ports (a bytevector of pre-encoded
;; requests in, a capturing writer out) with the real registry / evaluator / dispatch.
;; It deterministically exercises the whole server pipeline EXCEPT the thin tcp accept
;; wiring.
;;
;; Why not a real-socket test in the suite: a client and server sharing ONE Steel
;; runtime deadlock on a tight bencode request/response loop — Steel's in-process
;; native-thread scheduling starves one side during message I/O (an inter-op flush can
;; mask it, but it is not reliable). This is purely an in-process artifact; an external
;; client (separate process) is unaffected, which is why the standalone
;; clone+eval-over-socket probes work. So socket-level verification is left to
;; test/integration.sh; the suite tests the loop deterministically.
(require "steel-test/test.scm")
(require "responses.scm")
(require "../nrepl-server/server.scm")
(require "../nrepl-server/session.scm")
(require "../nrepl-server/evaluator.scm")
(require "../nrepl-server/bencode.scm")

;; Decode every bencode value from a bytevector into a list.
(define (decode-all bv)
  (let ([in (open-input-bytevector bv)])
    (let loop ([acc '()])
      (if (eof-object? (peek-byte in))
        (reverse acc)
        (loop (cons (bencode-decode in) acc))))))

;; Concatenate encoded requests into one input stream.
(define (encode-requests reqs)
  (let loop ([reqs reqs] [acc (bytes)])
    (if (null? reqs)
      acc
      (loop (cdr reqs) (bytes-append acc (bencode-encode (car reqs)))))))

;; Run serve-loop over an in-memory request stream; return the decoded responses.
(define (serve reg reqs)
  (let ([reader (open-input-bytevector (encode-requests reqs))]
        [out (open-output-bytevector)])
    (serve-loop reader (lambda (m) (write-bytes (bencode-encode m) out)) reg)
    (decode-all (get-output-bytevector out))))

;; Pre-create a session so requests can reference its id (clone's id is generated).
(define reg (make-registry (make-native-evaluator)))
(define sid (registry-clone! reg))

(define R
  (serve reg
    (list (hash "op" "eval" "id" "1" "session" sid "code" "(+ 40 2)")
      (hash "op" "eval" "id" "2" "session" sid "code" "(define yy 99)")
      (hash "op" "eval" "id" "3" "session" sid "code" "yy")
      (hash "op" "eval" "id" "4" "session" sid "code" "(display \"so\")")
      (hash "op" "eval" "id" "5" "session" sid "code" "(car '())")
      (hash "op" "describe" "id" "6")
      (hash "op" "ls-sessions" "id" "7")
      (hash "op" "bogus-op" "id" "8"))))

(deftest serve-loop-answers-every-request-test
  (testing "a batch of 8 requests over serve-loop"
    (is (= 8 (length (filter (lambda (r) (and (hash-contains? r "status")
                                          (member "done" (hash-ref r "status"))))
                      R)))
      "each one is terminated by a done")))

(deftest serve-loop-op-results-test
  (testing "over serve-loop"
    (testing "eval"
      (is (= (list "42") (collect (responses-for R "1") "value")) "reports a value")
      (is (= (list "99") (collect (responses-for R "3") "value")) "state persists")
      (is (= (list "so") (collect (responses-for R "4") "out")) "output is captured")
      (is (and (member "eval-error" (final-status (responses-for R "5"))) #t)
        "an error surfaces as eval-error"))
    (is (hash-contains? (car (responses-for R "6")) "ops") "describe reports ops")
    (is (and (member sid (hash-ref (car (responses-for R "7")) "sessions")) #t)
      "ls-sessions lists the session")
    (is (and (member "unknown-op" (hash-ref (car (responses-for R "8")) "status")) #t)
      "an unknown op is reported")))

(deftest serve-loop-malformed-frame-test
  (testing "a bencode framing error"
    ;; The loop must return rather than spin: bencode desync is unrecoverable, so
    ;; the connection is dropped.
    (is (let ([reader (open-input-bytevector (string->bytes "xnot-bencode"))])
         (serve-loop reader (lambda (m) #t) reg)
         #t)
      "stops the loop cleanly")))

(deftest server-error-response-test
  ;; The handler-bug fallback echoes id and session so the client can still route it.
  (testing "server-error-response"
    (let ([e (server-error-response (hash "op" "eval" "id" "e1" "session" "s-9") "boom")])
      (is (= "e1" (hash-ref e "id")) "echoes the id")
      (is (= "s-9" (hash-ref e "session")) "echoes the session")
      (is (and (member "server-error" (hash-ref e "status")) #t)
        "carries the server-error status"))))
