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
(define-module (bitcoin packages explorers)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages node)
  #:use-module (gnu packages rsync)
  #:use-module (bitcoin build npm-vendor)
  #:use-module (bitcoin packages rust-crates))

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

(define %mempool-rust-gbt-source
  ;; cargo-build-system needs Cargo.toml at the source root, but the gbt crate
  ;; lives at rust/gbt in the mempool tree.  Narrow the checkout to that
  ;; subdirectory: hoist its contents to the top level and drop everything
  ;; else.  (The snippet runs on the unpacked checkout copy.)
  (origin
    (inherit %mempool-source)
    (modules '((guix build utils)
               (ice-9 ftw)
               (srfi srfi-1)))
    (snippet
     #~(begin
         ;; Move rust/gbt/* (including dotfiles) to the top level, then
         ;; remove every other top-level entry.
         (let* ((gbt "rust/gbt")
                (keep (scandir gbt
                               (lambda (n)
                                 (not (member n '("." "..")))))))
           (for-each (lambda (entry)
                       (rename-file (string-append gbt "/" entry) entry))
                     keep)
           ;; Remove everything that wasn't hoisted (including rust/).
           (for-each delete-file-recursively
                     (scandir "."
                              (lambda (n)
                                (and (not (member n '("." "..")))
                                     (not (member n keep)))))))))))

(define-public mempool-rust-gbt
  ;; The mempool backend's 'rust-gbt' module is a napi-rs native addon: the
  ;; gbt crate (rust/gbt) compiled to a cdylib, plus the @napi-rs/cli-generated
  ;; index.js loader / index.d.ts types and the crate's package.json.  package
  ;; .json wires it into the backend as the "file:./rust-gbt" dependency.
  ;;
  ;; We build the cdylib with a regular cargo derivation (no cross-machine FOD
  ;; hash constraint) and pair it with the version-stable generated loader
  ;; files shipped as channel aux-files.  `cargo build --release` of a napi
  ;; crate yields a working cdylib on its own; the @napi-rs/cli only renames
  ;; and wraps it (which we do in the install phase).
  (package
    (name "mempool-rust-gbt")
    (version %mempool-version)
    (source %mempool-rust-gbt-source)
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #f
      ;; The crate's cargo tests don't matter here; the cdylib is the artifact.
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (replace 'install
            (lambda _
              (let* ((dir (string-append #$output "/lib/mempool-rust-gbt")))
                (mkdir-p dir)
                ;; index.js probes ./gbt.linux-x64-gnu.node on x86_64-linux-gnu;
                ;; install the cdylib (target/release/libgbt.so) under that
                ;; napi platform name.
                (install-file "target/release/libgbt.so" dir)
                (rename-file (string-append dir "/libgbt.so")
                             (string-append dir "/gbt.linux-x64-gnu.node"))
                ;; The crate's own package.json ("file:./rust-gbt" metadata).
                (install-file "package.json" dir)
                ;; Generated napi loader + type declarations (channel aux-files).
                (copy-file #$(local-file "aux-files/mempool-rust-gbt/index.js")
                           (string-append dir "/index.js"))
                (copy-file #$(local-file "aux-files/mempool-rust-gbt/index.d.ts")
                           (string-append dir "/index.d.ts"))))))))
    (inputs (lookup-cargo-inputs 'mempool-rust-gbt))
    (home-page "https://mempool.space/")
    (synopsis "getBlockTemplate algorithm reimplementation for mempool")
    (description
     "@code{rust-gbt} is the mempool backend's napi-rs native addon: an
efficient Rust reimplementation of Bitcoin's getBlockTemplate algorithm,
compiled to a Node native module (@file{gbt.linux-x64-gnu.node}) with the
generated loader and type declarations the backend's @code{file:./rust-gbt}
dependency resolves to.")
    (license license:agpl3)))

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
                (copy-recursively
                 #$(file-append mempool-rust-gbt "/lib/mempool-rust-gbt")
                 "rust-gbt")
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
