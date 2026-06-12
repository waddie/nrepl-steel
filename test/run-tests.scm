;; Top-level test runner. Requires each module's test file, then prints a summary
;; and exits non-zero (via an uncaught error) if anything failed.
;;
;; Run with:  steel test/run-tests.scm     (from the repo root)
;;        or:  ./run-tests.sh

(require "harness.scm")

;; --- suites ---------------------------------------------------------------
;; Add a (require "<module>-test.scm") line per module as suites land.
(require "bencode-test.scm")
(require "transport-test.scm")
(require "session-test.scm")
(require "dispatch-test.scm")
(require "server-test.scm")

;; Smoke test so an empty suite still exercises the harness end to end.
(check-equal? "harness smoke" (+ 40 2) 42)

;; --------------------------------------------------------------------------
(summary!)
