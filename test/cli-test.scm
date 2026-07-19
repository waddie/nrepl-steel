;; Tests for nrepl-server/cli.scm
;;
;; Argument parsing and port extraction are pure, so they are driven with synthetic argv
;; lists shaped like (command-line): (steel <script> args...). write-port-file! touches
;; the filesystem and is left to test/integration.sh, which asserts on the real file.
(require "steel-test/test.scm")
(require "../nrepl-server/cli.scm")

;; A (command-line) as Steel presents it for `steel <script> args...`.
(define (argv . args) (append (list "steel" "nrepl-steel.scm") args))

(deftest cli-addr-test
  (testing "listen address"
    (is (= DEFAULT-ADDR (cli-addr (argv))) "defaults when no argument is given")
    (is (= "127.0.0.1:9000" (cli-addr (argv "127.0.0.1:9000")))
      "takes an explicit host:port")
    (is (= DEFAULT-ADDR (cli-addr (argv "--no-port-file")))
      "a lone flag is not mistaken for an address")
    (is (= "127.0.0.1:9000" (cli-addr (argv "--no-port-file" "127.0.0.1:9000")))
      "finds the address after a flag")
    (is (= "127.0.0.1:9000" (cli-addr (argv "127.0.0.1:9000" "--no-port-file")))
      "finds the address before a flag")))

(deftest cli-port-file-flag-test
  (testing "--no-port-file"
    (is (cli-write-port-file? (argv)) "writing is the default")
    (is (cli-write-port-file? (argv "127.0.0.1:9000")) "an address alone still writes")
    (is (not (cli-write-port-file? (argv "--no-port-file"))) "the flag suppresses writing")
    (is (not (cli-write-port-file? (argv "127.0.0.1:9000" "--no-port-file")))
      "the flag suppresses writing alongside an address")))

(deftest cli-addr-port-test
  (testing "port extraction"
    (is (= "7888" (addr-port "127.0.0.1:7888")) "ipv4 host:port")
    (is (= "9000" (addr-port "localhost:9000")) "named host")
    ;; The file must carry the port alone, so a bracketed IPv6 host must not leak its
    ;; own colons into it.
    (is (= "7888" (addr-port "[::1]:7888")) "bracketed ipv6 host")))
