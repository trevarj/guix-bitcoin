;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- fixed-output origins for Go module dependencies.
(define-module (btc build go-vendor)
  #:use-module (guix gexp)
  #:use-module (guix base32)
  #:use-module (guix modules)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages version-control)
  #:export (go-mod-vendored-source))

(define* (go-mod-vendored-source #:key name source hash go)
  "Return a fixed-output derivation producing SOURCE with a populated
@file{vendor/} directory, created by running @command{go mod vendor} with
network access.  HASH is the expected sha256 (nar serializer, nix-base32
string) of the result.  GO is the Go toolchain package to use.

Because the result is hash-pinned the build runs as a fixed-output
derivation, which guix-daemon grants network access; the builder is given
@command{git} (for VCS-based module fetches) and TLS root certificates."
  (computed-file
   (string-append name "-vendored")
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils))
         (copy-recursively #$source #$output)
         ;; A writable HOME/GOPATH and CA certificates are required for the
         ;; module downloads performed by 'go mod vendor'.
         (setenv "HOME" "/tmp")
         (setenv "GOPATH" "/tmp/go")
         (setenv "GOCACHE" "/tmp/go-cache")
         (setenv "GOFLAGS" "-mod=mod")
         ;; Guix's nss-certs ships individual PEMs plus hashed symlinks in
         ;; /etc/ssl/certs (no single bundle file), so point the directory
         ;; variables at it rather than a *.crt bundle.
         (setenv "SSL_CERT_DIR"
                 #$(file-append nss-certs "/etc/ssl/certs"))
         (setenv "GIT_SSL_CAPATH"
                 #$(file-append nss-certs "/etc/ssl/certs"))
         ;; 'go mod vendor' shells out to git for some modules.
         (setenv "PATH"
                 (string-append #$(file-append git "/bin") ":"
                                (or (getenv "PATH") "")))
         (with-directory-excursion #$output
           (invoke #$(file-append go "/bin/go") "mod" "vendor"))))
   ;; computed-file passes OPTIONS straight to gexp->derivation; the hash
   ;; keywords below turn this into a recursive (nar) fixed-output
   ;; derivation, mirroring how (guix git-download) builds its FODs.
   #:options (list #:hash-algo 'sha256
                   #:hash (nix-base32-string->bytevector hash)
                   #:recursive? #t
                   #:local-build? #t)))
