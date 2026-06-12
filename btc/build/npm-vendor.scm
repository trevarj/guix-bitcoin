;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- fixed-output origins for npm dependency caches.
(define-module (btc build npm-vendor)
  #:use-module (guix gexp)
  #:use-module (guix base32)
  #:use-module (guix modules)
  #:use-module (gnu packages nss)
  #:export (npm-offline-cache))

(define* (npm-offline-cache #:key name source subdirectory hash node)
  "Return a fixed-output derivation containing an npm cache directory
populated by @command{npm ci --cache} for SOURCE's SUBDIRECTORY (which must
contain @file{package.json} and @file{package-lock.json}).  HASH is the
expected sha256 (nar serializer, nix-base32 string) of the result.  NODE is
the Node.js package providing @command{npm}.

Because the result is hash-pinned the build runs as a fixed-output
derivation, which guix-daemon grants network access; TLS root certificates
are supplied so npm can reach the registry."
  (computed-file
   (string-append name "-npm-cache")
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils))
         ;; npm wants a writable project tree and HOME.
         (copy-recursively (string-append #$source "/" #$subdirectory)
                           "/tmp/app")
         (setenv "HOME" "/tmp")
         ;; Guix's nss-certs ships individual PEMs plus hashed symlinks in
         ;; /etc/ssl/certs (no single bundle file), so point the directory
         ;; variable at it rather than a *.crt bundle.
         (setenv "SSL_CERT_DIR"
                 #$(file-append nss-certs "/etc/ssl/certs"))
         (mkdir-p #$output)
         (with-directory-excursion "/tmp/app"
           (invoke #$(file-append node "/bin/npm")
                   "ci" "--ignore-scripts" "--no-audit" "--no-fund"
                   (string-append "--cache=" #$output)))))
   ;; computed-file passes OPTIONS straight to gexp->derivation; the hash
   ;; keywords below turn this into a recursive (nar) fixed-output
   ;; derivation, mirroring how (guix git-download) builds its FODs.
   #:options (list #:hash-algo 'sha256
                   #:hash (nix-base32-string->bytevector hash)
                   #:recursive? #t
                   #:local-build? #t)))
