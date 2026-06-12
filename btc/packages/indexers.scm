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
(define-module (btc packages indexers)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages databases)
  #:use-module (gnu packages jemalloc)
  #:use-module (gnu packages llvm)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages qt)
  #:use-module (btc packages rust-crates))

(define-public fulcrum
  (package
    (name "fulcrum")
    (version "2.1.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/cculianu/Fulcrum")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "07qr6xzpck47ay0k3i2a3pj5nbbk3zi8wmykh06yl3cl387361fa"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f ;no test suite
      #:phases
      #~(modify-phases %standard-phases
          (replace 'configure
            (lambda _
              ;; Fulcrum.pro detects a "LIBS+=-lrocksdb"/"-ljemalloc"
              ;; override on the qmake command line and links the system
              ;; libraries instead of its bundled static copies (see the
              ;; "using CLI override" branches in Fulcrum.pro).  There is
              ;; no "config_without_bundled_*" knob.
              (invoke "qmake" "Fulcrum.pro"
                      (string-append "PREFIX="
                                     #$output)
                      "LIBS+=-lrocksdb -ljemalloc -lz"))))))
    (native-inputs (list pkg-config))
    (inputs (list qtbase-5 rocksdb jemalloc zlib))
    (home-page "https://github.com/cculianu/Fulcrum")
    (synopsis "Fast SPV server for Bitcoin")
    (description
     "Fulcrum is a fast SPV (Electrum protocol) server indexing the Bitcoin
block chain from a trusted full node, serving wallet clients such as
Electrum.")
    (license license:gpl3+)))

(define-public electrs
  (package
    (name "electrs")
    (version "0.11.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/romanz/electrs")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0p22ga5g6v160678cqnqasrzwljddgdmbsy8rmzhdd9f5z06dsk6"))))
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #f
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'build 'set-libclang-path
            (lambda _
              ;; Build the bundled RocksDB (upstream's default; the test
              ;; suite expects its exact version/options — Guix's rocksdb
              ;; lacks options electrs opens databases with).  bindgen
              ;; needs libclang.
              (setenv "LIBCLANG_PATH"
                      #$(file-append clang "/lib")))))))
    (native-inputs (list clang pkg-config))
    (inputs (cons `(,zstd "lib")
                  (lookup-cargo-inputs 'electrs)))
    (home-page "https://github.com/romanz/electrs")
    (synopsis "Efficient re-implementation of Electrum Server in Rust")
    (description
     "electrs indexes the Bitcoin block chain served by a trusted full node
and provides the Electrum wallet protocol to clients, with low resource
requirements suitable for personal servers.")
    (license license:expat)))
