;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- fixed-output origins for vendored napi-rs native modules.
(define-module (btc build napi-vendor)
  #:use-module (guix gexp)
  #:use-module (guix base32)
  #:use-module (guix modules)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages rust)
  #:use-module (gnu packages commencement)
  #:export (napi-vendored-module))

(define* (napi-vendored-module #:key name
                               source
                               subdirectory
                               hash
                               node)
  "Return a fixed-output derivation containing the build artifacts of a
napi-rs (@url{https://napi.rs}) native Node module: the compiled
@file{*.node} cdylib plus the @code{@napi-rs/cli}-generated @file{index.js}
loader and @file{index.d.ts} type definitions, alongside the crate's
@file{package.json}.  This is exactly the directory the mempool backend's
@code{file:./rust-gbt} dependency resolves to.

SOURCE's SUBDIRECTORY must be a napi-rs crate (Cargo + @file{package.json}
with a @code{napi} stanza, as produced by @command{napi build}).  HASH is the
expected sha256 (nar serializer, nix-base32 string) of the result.  NODE
provides @command{npm}/@command{node}.

@command{napi build} (via @code{@napi-rs/cli}) both compiles the cdylib and
emits @file{index.js}/@file{index.d.ts} from the @code{#[napi]} type metadata
the Rust crate records during compilation; hand-writing those generated files
would be fragile, so we run the upstream toolchain.  Because the result is
hash-pinned the build runs as a fixed-output derivation, which guix-daemon
grants network access (cargo fetches crates, npm fetches @code{@napi-rs/cli});
TLS root certificates are supplied accordingly.

Determinism: the upstream @code{build-release} script passes
@code{--release --strip}, and we flatten all mtimes on the output, so the FOD
hash is stable across runs (verify with @command{guix build --check})."
  (computed-file
   (string-append name "-napi-module")
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils)
                      (ice-9 popen)
                      (ice-9 textual-ports))
         ;; Per-derivation scratch (not literal /tmp): with --disable-chroot
         ;; CI containers share /tmp between build users.
         (define scratch
           (string-append (or (getenv "TMPDIR") "/tmp") "/napi-vendor"))
         (copy-recursively (string-append #$source "/" #$subdirectory)
                           scratch
                           #:keep-permissions? #f)
         ;; The store tree is read-only; cargo/napi/npm need to write the
         ;; crate dir (lockfiles, target/, node_modules, *.node, index.*).
         (for-each (lambda (f)
                     (let ((s (lstat f)))
                       (unless (eq? 'symlink (stat:type s))
                         (chmod f (logior #o200 (stat:perms s))))))
                   (cons scratch
                         (find-files scratch (const #t) #:directories? #t)))
         (setenv "HOME" scratch)
         ;; Toolchain on PATH: cargo + rustc (rust), cc + linker
         ;; (gcc-toolchain), npm + node (NODE), bash (npm runs scripts via
         ;; `sh`), plus coreutils + grep for the check-cargo-version shell
         ;; helper.
         (setenv "PATH"
                 (string-join
                  (list (string-append #$rust "/bin")
                        (string-append #$gcc-toolchain "/bin")
                        (string-append #$node "/bin")
                        (string-append #$bash-minimal "/bin")
                        (string-append #$coreutils "/bin")
                        (string-append #$grep "/bin")
                        (or (getenv "PATH") ""))
                  ":"))
         ;; napi-rs/cli shells out to `cc` for the final link step.
         (setenv "CC" (string-append #$gcc-toolchain "/bin/gcc"))
         ;; Guix's nss-certs ships hashed symlinks in /etc/ssl/certs (no
         ;; single bundle); point the directory variable at it.
         (setenv "SSL_CERT_DIR"
                 #$(file-append nss-certs "/etc/ssl/certs"))
         (with-directory-excursion scratch
           ;; Upstream `build-release` runs, in one npm script:
           ;;   npm install --no-save @napi-rs/cli && check-cargo-version
           ;;     && napi build --platform --release --strip
           ;; We run the steps directly rather than via `npm run` because the
           ;; @napi-rs/cli entry point has a "#!/usr/bin/env node" shebang and
           ;; /usr/bin/env does not exist in the build sandbox; invoking it
           ;; with an explicit `node` avoids that and avoids npm spawning a
           ;; shell to re-exec the .bin shim.
           (invoke #$(file-append node "/bin/npm")
                   "install" "--no-save" "@napi-rs/cli@2.18.0"
                   "--no-audit" "--no-fund")
           ;; check-cargo-version is warn-only upstream: rust-toolchain pins a
           ;; cargo version Guix's `rust` need not match.  Mirror the warning.
           (let ((pinned (string-trim-right
                          (call-with-input-file "rust-toolchain"
                            (lambda (p) (get-string-all p))))))
             (unless (string-contains
                      (let* ((pipe (open-pipe* OPEN_READ "cargo" "version"))
                             (out (get-string-all pipe)))
                        (close-pipe pipe)
                        out)
                      (string-append "cargo " pinned))
               (format (current-error-port)
                       "WARNING: cargo version mismatch with \
rust-toolchain (~a); building with Guix's rust anyway.~%"
                       pinned)))
           ;; napi build: compiles the cdylib and emits index.js/index.d.ts.
           (invoke #$(file-append node "/bin/node")
                   "node_modules/@napi-rs/cli/scripts/index.js"
                   "build" "--platform" "--release" "--strip"))
         ;; Mirror upstream `to-backend`: ship exactly the files the backend
         ;; copies into ./rust-gbt/ (index.js index.d.ts package.json *.node).
         (mkdir-p #$output)
         (for-each
          (lambda (f)
            (let ((src (string-append scratch "/" f)))
              (when (file-exists? src)
                (copy-file src (string-append #$output "/" f)))))
          '("index.js" "index.d.ts" "package.json"))
         (for-each
          (lambda (node-file)
            (copy-file node-file
                       (string-append #$output "/"
                                      (basename node-file))))
          (find-files scratch "\\.node$"))
         ;; Flatten mtimes -- the main source of FOD nondeterminism.
         (for-each (lambda (f)
                     (utime f 1 1 1 1 AT_SYMLINK_NOFOLLOW))
                   (find-files #$output (const #t) #:directories? #t))
         (utime #$output 1 1 1 1)))
   #:options (list #:hash-algo 'sha256
                   #:hash (nix-base32-string->bytevector hash)
                   #:recursive? #t
                   #:local-build? #t)))
