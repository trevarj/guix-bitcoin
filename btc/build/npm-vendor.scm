;;; Copyright © 2026 Trevor Arjeski <tmarjeski@gmail.com>
;;;
;;; This file is part of guix-bitcoin.
;;;
;;; guix-bitcoin is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by the
;;; Free Software Foundation; either version 3 of the License, or (at your
;;; option) any later version.
;;;
;;; guix-bitcoin --- fixed-output origins for vendored npm node_modules.
(define-module (btc build npm-vendor)
  #:use-module (guix gexp)
  #:use-module (guix base32)
  #:use-module (guix modules)
  #:use-module (gnu packages nss)
  #:export (npm-vendored-modules))

(define* (npm-vendored-modules #:key name
                               source
                               subdirectory
                               hash
                               node
                               ;; "ci" needs package.json and the lockfile
                               ;; in strict sync; some upstreams (mempool
                               ;; frontend) only support "install".  The
                               ;; FOD hash still pins the result.
                               (npm-command "ci"))
  "Return a fixed-output derivation containing a normalized @file{node_modules}
tree produced by @command{npm ci} for SOURCE's SUBDIRECTORY (which must contain
@file{package.json} and @file{package-lock.json}).  HASH is the expected sha256
(nar serializer, nix-base32 string) of the result.  NODE is the Node.js package
providing @command{npm}.

Unlike npm's own @file{cacache} store (whose index embeds timestamps and is
therefore not bit-reproducible), the installed @file{node_modules} tree is
deterministic once its file mtimes are flattened and npm's bookkeeping files
are stripped.  We install with @code{npm ci} and then normalize the tree so the
resulting FOD hash is stable across CI runs.

Because the result is hash-pinned the build runs as a fixed-output
derivation, which guix-daemon grants network access; TLS root certificates
are supplied so npm can reach the registry."
  (computed-file (string-append name "-node-modules")
                 (with-imported-modules (source-module-closure '((guix build
                                                                       utils)))
                                        #~(begin
                                            (use-modules (guix build utils))
                                            ;; Use the per-derivation scratch directory, NOT
                                            ;; the literal /tmp: with --disable-chroot (CI
                                            ;; containers) /tmp is shared between builds, and
                                            ;; a leftover tree owned by another build user
                                            ;; makes the copy fail with EACCES.
                                            (define scratch
                                              (string-append (or (getenv "TMPDIR") "/tmp")
                                                             "/npm-vendor-app"))
                                            ;; npm wants a writable project tree and HOME.
                                            ;; Don't keep the store's read-only directory
                                            ;; permissions, or nested copies fail.
                                            (copy-recursively (string-append #$source
                                                               "/"
                                                               #$subdirectory)
                                                              scratch
                                                              #:keep-permissions? #f)
                                            ;; copy-file preserves the store's read-only
                                            ;; file modes; npm install rewrites the
                                            ;; lockfile, so make the tree owner-writable.
                                            (for-each (lambda (f)
                                                        (let ((s (lstat f)))
                                                          (unless (eq? 'symlink
                                                                       (stat:type s))
                                                            (chmod f
                                                                   (logior #o200
                                                                           (stat:perms s))))))
                                                      (cons scratch
                                                            (find-files scratch
                                                                        (const #t)
                                                                        #:directories? #t)))
                                            (setenv "HOME" scratch)
                                            ;; Guix's nss-certs ships individual PEMs plus hashed symlinks in
                                            ;; /etc/ssl/certs (no single bundle file), so point the directory
                                            ;; variable at it rather than a *.crt bundle.
                                            (setenv "SSL_CERT_DIR"
                                                    #$(file-append nss-certs
                                                       "/etc/ssl/certs"))
                                            (with-directory-excursion scratch
                                              (invoke #$(file-append node
                                                         "/bin/npm")
                                                      #$npm-command
                                                      "--ignore-scripts"
                                                      "--no-audit" "--no-fund"))
                                            ;; Ship the installed dependency tree itself.
                                            (copy-recursively
                                             (string-append scratch "/node_modules")
                                             #$output)
                                            ;; Drop npm's own bookkeeping copy of the lockfile
                                            ;; (its mtime/ordering is install-run dependent).
                                            (let ((stray (string-append #$output
                                                          "/.package-lock.json")))
                                              (when (file-exists? stray)
                                                (delete-file stray)))
                                            ;; Flatten all mtimes/atimes (the main source of
                                            ;; nondeterminism) on every file, directory and
                                            ;; symlink, without following symlinks.
                                            (for-each (lambda (f)
                                                        (utime f
                                                         1
                                                         1
                                                         1
                                                         1
                                                         AT_SYMLINK_NOFOLLOW))
                                                      (find-files #$output
                                                                  (const #t)
                                                                  #:directories?
                                                                  #t))
                                            ;; The output directory root itself is not returned
                                            ;; by find-files; normalize it too.
                                            (utime #$output 1 1 1 1)))
                 ;; computed-file passes OPTIONS straight to gexp->derivation; the hash
                 ;; keywords below turn this into a recursive (nar) fixed-output
                 ;; derivation, mirroring how (guix git-download) builds its FODs.
                 #:options (list #:hash-algo 'sha256
                                 #:hash (nix-base32-string->bytevector hash)
                                 #:recursive? #t
                                 #:local-build? #t)))
