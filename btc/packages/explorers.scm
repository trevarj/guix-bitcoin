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
  #:use-module (btc build npm-vendor))

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

(define %backend-npm-cache
  (npm-offline-cache #:name "mempool-backend"
                     #:source %mempool-source
                     #:subdirectory "backend"
                     #:hash
                     "0px1x252rxwrjslqh07123x67rnpv5z5afs8wq9dyhqy0fildc19"
                     #:node node-lts))

;; FIXME: real hash from first build.
(define %frontend-npm-cache
  (npm-offline-cache #:name "mempool-frontend"
                     #:source %mempool-source
                     #:subdirectory "frontend"
                     #:hash
                     "0000000000000000000000000000000000000000000000000000"
                     #:node node-lts))

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
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (replace 'build
            (lambda _
              (setenv "HOME" "/tmp")
              (with-directory-excursion "backend"
                (invoke #$(file-append node-lts "/bin/npm")
                        "ci"
                        "--offline"
                        "--ignore-scripts"
                        "--no-audit"
                        "--no-fund"
                        (string-append "--cache="
                                       #$%backend-npm-cache))
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
                (invoke #$(file-append node-lts "/bin/npm")
                        "ci"
                        "--offline"
                        "--ignore-scripts"
                        "--no-audit"
                        "--no-fund"
                        (string-append "--cache="
                                       #$%frontend-npm-cache))
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
    (native-inputs (list node-lts))
    (home-page "https://mempool.space/")
    (synopsis "Mempool and block explorer frontend (static assets)")
    (description
     "Pre-built static web assets of the mempool explorer's Angular
frontend, for serving via nginx in front of @code{mempool-backend}.")
    (license license:agpl3)))
