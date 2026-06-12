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
(define-module (btc packages lightning)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages crypto)
  #:use-module (gnu packages gettext)
  #:use-module (gnu packages golang)
  #:use-module (gnu packages markup)
  #:use-module (gnu packages multiprecision)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages sqlite)
  #:use-module (gnu packages web)
  #:use-module (btc build go-vendor))

(define-public core-lightning
  (package
    (name "core-lightning")
    (version "26.06.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/ElementsProject/lightning")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "059jbwy0n3vgjr9m519g23zvb95mp5aaasl72qvcxa27f20d4c23"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f ;test suite needs running bitcoind
      #:configure-flags
      ;; Rust plugins (cln-grpc, clnrest, …) pull a full cargo tree;
      ;; keep the core daemon pure-C for now.  Valgrind is autodetected
      ;; and simply absent here, so no explicit --disable-valgrind.
      #~(list "--disable-rust")
      #:phases
      #~(modify-phases %standard-phases
          ;; Bespoke ./configure rejects standard GNU flags.
          (replace 'configure
            (lambda* (#:key configure-flags #:allow-other-keys)
              (setenv "CC"
                      #$(cc-for-target))
              (apply invoke "./configure"
                     (string-append "--prefix="
                                    #$output) configure-flags))))))
    (native-inputs (list autoconf
                         automake
                         libtool
                         gettext-minimal
                         jq
                         lowdown
                         pkg-config
                         python
                         python-mako
                         which))
    (inputs (list gmp libsodium sqlite zlib))
    (home-page "https://github.com/ElementsProject/lightning")
    (synopsis "Lightning Network implementation in C")
    (description
     "Core Lightning (CLN) is a standard-compliant implementation of the
Lightning Network protocol, providing @command{lightningd} and the
@command{lightning-cli} control tool, with a plugin architecture for
extensions.")
    (license license:bsd-3)))

(define-public lnd
  (let* ((version "0.20.1-beta")
         ;; FIXME: real hash from first build — until the go-mod-vendor FOD
         ;; runs once, this all-zeros placeholder makes the build fail with
         ;; the actual hash to splice in here (standard Guix FOD workflow).
         (vendored-hash "0000000000000000000000000000000000000000000000000000")
         (plain-source (origin
                         (method git-fetch)
                         (uri (git-reference
                               (url "https://github.com/lightningnetwork/lnd")
                               (commit (string-append "v" version))))
                         (file-name (git-file-name "lnd" version))
                         (sha256 (base32
                                  "01fkylbifb7snlk49r1q7r7ywky0v3iyyiw3kl0b2a42ax9b4z0h")))))
    (package
      (name "lnd")
      (version version)
      ;; The source is the plain checkout with a populated vendor/ directory,
      ;; produced by the fixed-output 'go mod vendor' helper (origins compose
      ;; here because computed-file is a valid file-like source).
      (source
       (go-mod-vendored-source #:name "lnd"
                               #:source plain-source
                               #:hash vendored-hash
                               #:go go-1.25))
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
                (setenv "GOFLAGS" "-mod=vendor -trimpath")
                (setenv "CGO_ENABLED" "0")
                ;; Upstream RELEASE_TAGS (make/release_flags.mk).
                (invoke "go"
                        "build"
                        "-o"
                        "lnd-bin/"
                        "-tags"
                        (string-append
                         "autopilotrpc signrpc walletrpc chainrpc "
                         "invoicesrpc watchtowerrpc neutrinorpc "
                         "monitoring peersrpc kvdb_postgres kvdb_etcd "
                         "kvdb_sqlite")
                        "./cmd/lnd"
                        "./cmd/lncli")))
            (replace 'install
              (lambda _
                (for-each (lambda (f)
                            (install-file f
                                          (string-append #$output "/bin")))
                          '("lnd-bin/lnd" "lnd-bin/lncli")))))))
      (native-inputs (list go-1.25))
      (home-page "https://github.com/lightningnetwork/lnd")
      (synopsis "Lightning Network daemon in Go")
      (description
       "lnd is a complete implementation of a Lightning Network node,
providing @command{lnd} and the @command{lncli} command-line tool, with
gRPC and REST interfaces for wallet and channel management.")
      (license license:expat))))
