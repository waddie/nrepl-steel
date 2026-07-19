;; Top-level test runner. Requires each module's test file — which registers its
;; deftests with steel-test as a load side effect — then runs the whole suite and
;; exits non-zero (via the raise inside run-tests!) if anything failed.
;;
;; Run with:  steel test/run-tests.scm     (from the repo root)
;;        or:  ./run-tests.sh
;;
;; Needs the steel-test cog installed in $STEEL_HOME/cogs (see run-tests.sh).

(require "steel-test/test.scm")

;; --- suites ---------------------------------------------------------------
;; Add a (require "<module>-test.scm") line per module as suites land. Tests run
;; in the order they are registered, so this list also fixes suite order.
(require "bencode-test.scm")
(require "transport-test.scm")
(require "session-test.scm")
(require "dispatch-test.scm")
(require "server-test.scm")

;; --------------------------------------------------------------------------
(run-tests!)
