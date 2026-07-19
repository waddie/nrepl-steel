;; version.scm — the versions the server reports in `describe`.
;;
;; nrepl-steel-version must match cog.scm's `version` and the Cargo.toml
;; [workspace.package] version; the release workflow verifies all three against
;; the tag being released, so a drift here fails the release.

(provide nrepl-steel-version steel-version-string)

(define nrepl-steel-version "0.2.6")

;; The Steel runtime version. Tracks the steel-core pin in the root Cargo.toml
;; (the git rev the installed `steel 0.8.2` was built from).
(define steel-version-string "0.8.2")
