;;; cog.scm - Forge package manifest for nrepl-steel
;;;
;;; Installable with Steel's package manager:
;;;
;;;   forge pkg install --git https://github.com/waddie/nrepl-steel
;;;
;;; Forge copies this directory to ~/.steel/cogs/nrepl-steel/, installs the
;;; entrypoint to ~/.steel/bin/nrepl-steel, and downloads the matching prebuilt
;;; dylib (see `dylibs` below) to ~/.steel/native/. The dylib name "nrepl_steel_engine"
;;; gains the platform prefix/extension, producing the libnrepl_steel_engine.{dylib,so}
;;; / nrepl_steel_engine.dll that evaluator.scm loads via
;;; (#%require-dylib "libnrepl_steel_engine" ...).

(define package-name 'nrepl-steel)
(define version "0.2.2")

;; No pure-Scheme dependencies — the evaluation backend is the native dylib below.
(define dependencies '())

;; Entrypoint — installed to $STEEL_HOME/bin/nrepl-steel
(define entrypoint '(#:name "nrepl-steel" #:path "bin/nrepl-steel.scm"))

;; The session-engine backend. Built from crates/nrepl-steel-engine; forge fetches the
;; prebuilt artifact for the host platform. Forge reads this file as data (no
;; evaluation), so these URLs are literal and must be bumped to match `version`
;; on each release (the release workflow guards against drift).
(define dylibs
  '((#:name
     "nrepl_steel_engine"
     #:urls
     ((#:platform
       "aarch64-macos"
       #:url
       "https://github.com/waddie/nrepl-steel/releases/download/v0.2.2/libnrepl_steel_engine-aarch64-macos.dylib")
      (#:platform
       "x86_64-macos"
       #:url
       "https://github.com/waddie/nrepl-steel/releases/download/v0.2.2/libnrepl_steel_engine-x86_64-macos.dylib")
      (#:platform
       "x86_64-linux"
       #:url
       "https://github.com/waddie/nrepl-steel/releases/download/v0.2.2/libnrepl_steel_engine-x86_64-linux.so")
      (#:platform
       "x86_64-windows"
       #:url
       "https://github.com/waddie/nrepl-steel/releases/download/v0.2.2/nrepl_steel_engine-x86_64-windows.dll")))))
