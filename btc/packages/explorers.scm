;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages explorers)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages node)
  #:use-module (gnu packages rsync)
  #:use-module (btc build npm-vendor)
  #:use-module (btc build napi-vendor))

(define %mempool-version
  "3.3.1")

(define %mempool-source
  (origin
    (method git-fetch)
    (uri (git-reference
          (url "https://github.com/mempool/mempool")
          (commit (string-append "v" %mempool-version))))
    (file-name (git-file-name "mempool" %mempool-version))
    (sha256 (base32 "04g67zmc5ppiaib7rp4csn0kwg1yrph9dkaklznyk0bhmjxshbrz"))))

(define %backend-node-modules
  (npm-vendored-modules #:name "mempool-backend"
   #:source %mempool-source
   #:subdirectory "backend"
   #:hash "01jqchx302q9fjjlsglzc9krq61vbilr2xzxjz633050ia6f49p2"
   #:node node-lts))

(define %backend-rust-gbt
  ;; The backend's 'rust-gbt' module is a napi-rs native addon living in the
  ;; mempool tree at rust/gbt; package.json wires it as "file:./rust-gbt" and
  ;; an upstream preinstall script builds it.  Our npm FOD installs with
  ;; --ignore-scripts, so we build the addon here (cdylib + generated
  ;; index.js/index.d.ts) and drop it into backend/rust-gbt before tsc runs.
  (napi-vendored-module #:name "mempool-rust-gbt"
   #:source %mempool-source
   #:subdirectory "rust/gbt"
   #:hash "1dmsnxk28hgixjh83hk6ghgqyym2rckd0rmcyywcpyjb6r9clac0"
   #:node node-lts))

(define %frontend-node-modules
  (npm-vendored-modules #:name "mempool-frontend"
   #:source %mempool-source
   #:subdirectory "frontend"
   #:hash "0ip8k7rq5c5172dvldchw3zzsr914xmhj9k08dyffkrqg443zaqq"
   #:node node-lts
   ;; v3.3.1 lockfile is not in strict "ci" sync (upstream installs).
   #:npm-command "install"))

(define-public mempool-backend
  (package
    (name "mempool-backend")
    (version %mempool-version)
    (source
     %mempool-source)
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      ;; node_modules ships prebuilt napi blobs (no Guix RUNPATH);
      ;; vendored-tier app, validation intentionally relaxed.
      #:validate-runpath? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (setenv "HOME" "/tmp")
              (with-directory-excursion "backend"
                ;; Drop in the pre-vendored, normalized dependency tree
                ;; instead of running 'npm ci' against a cache.
                (copy-recursively #$%backend-node-modules "node_modules")
                ;; node_modules/rust-gbt is a symlink to ../rust-gbt (the
                ;; "file:./rust-gbt" dependency); populate that target with
                ;; the pre-built napi addon so tsc resolves 'rust-gbt'.
                (mkdir-p "rust-gbt")
                (copy-recursively #$%backend-rust-gbt "rust-gbt")
                ;; Replace the file: dependency's symlink with a real
                ;; copy so the installed tree is self-contained (the
                ;; symlink would dangle under lib/mempool-backend).
                (when (eq? 'symlink
                           (stat:type (lstat "node_modules/rust-gbt")))
                  (delete-file "node_modules/rust-gbt")
                  (copy-recursively "rust-gbt" "node_modules/rust-gbt"))
                ;; The vendored scripts carry /usr/bin/env shebangs,
                ;; which don't exist in the build environment.
                ;; Regular files only: patching through a .bin/ symlink
                ;; would replace it with a regular-file copy, breaking
                ;; the target's relative requires.
                (for-each (lambda (f)
                            (false-if-exception (patch-shebang f)))
                          (find-files "node_modules"
                                      (lambda (f s)
                                        (and (eq? 'regular (stat:type s))
                                             (executable-file? f)))))
                (invoke #$(file-append node-lts "/bin/npm") "run" "build"))))
          (replace 'install
            (lambda _
              (let ((lib (string-append #$output "/lib/mempool-backend"))
                    (bin (string-append #$output "/bin")))
                (with-directory-excursion "backend"
                  (copy-recursively "dist"
                                    (string-append lib "/dist"))
                  (copy-recursively "node_modules"
                                    (string-append lib "/node_modules")))
                (mkdir-p bin)
                ;; Wrapper exec'ing node on the compiled entrypoint.
                ;; The runtime /bin/sh (bash-minimal) and node-lts are
                ;; retained in the package's closure via these gexp
                ;; references.
                (let ((wrapper (string-append bin "/mempool-backend")))
                  (call-with-output-file wrapper
                    (lambda (port)
                      (format port
                       "#!~a~%exec ~a/bin/node ~a/dist/index.js \"$@\"~%"
                       #$(file-append bash-minimal "/bin/sh")
                       #$node-lts lib)))
                  (chmod wrapper #o555))))))))
    (native-inputs (list node-lts bash-minimal))
    (home-page "https://mempool.space/")
    (synopsis "Mempool and block explorer backend")
    (description
     "The mempool open-source project's backend daemon: indexes mempool and
block data from a Bitcoin node and an Electrum server into MariaDB and
serves the explorer's REST and WebSocket APIs.")
    (license license:agpl3)))

(define-public mempool-frontend
  (package
    (name "mempool-frontend")
    (version %mempool-version)
    (source
     %mempool-source)
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      ;; node_modules ships prebuilt napi blobs (no Guix RUNPATH);
      ;; vendored-tier app, validation intentionally relaxed.
      #:validate-runpath? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (setenv "HOME" "/tmp")
              ;; The 'sync-assets' build step downloads mining-pool and
              ;; other resources over HTTPS; SKIP_SYNC/DRY_RUN keep the
              ;; production build offline.  'generate-config' and
              ;; 'generate-themes' only write local files.
              (setenv "SKIP_SYNC" "1")
              (setenv "DRY_RUN" "1")
              (with-directory-excursion "frontend"
                ;; Drop in the pre-vendored, normalized dependency tree
                ;; instead of running 'npm ci' against a cache.
                (copy-recursively #$%frontend-node-modules "node_modules")
                ;; The vendored scripts carry /usr/bin/env shebangs,
                ;; which don't exist in the build environment.
                ;; Regular files only: patching through a .bin/ symlink
                ;; would replace it with a regular-file copy, breaking
                ;; the target's relative requires.
                (for-each (lambda (f)
                            (false-if-exception (patch-shebang f)))
                          (find-files "node_modules"
                                      (lambda (f s)
                                        (and (eq? 'regular (stat:type s))
                                             (executable-file? f)))))
                (invoke #$(file-append node-lts "/bin/npm") "run" "build"))))
          (replace 'install
            (lambda _
              ;; Angular's --localize build emits the source locale into
              ;; dist/mempool/browser and other locales into per-locale
              ;; subdirectories; ship the whole dist as the static web
              ;; root (nginx serves .../mempool/browser).
              (copy-recursively "frontend/dist"
                                (string-append #$output
                                               "/share/mempool-frontend")))))))
    (native-inputs (list node-lts rsync))
    (home-page "https://mempool.space/")
    (synopsis "Mempool and block explorer frontend (static assets)")
    (description
     "Pre-built static web assets of the mempool explorer's Angular
frontend, for serving via nginx in front of @code{mempool-backend}.")
    (license license:agpl3)))
