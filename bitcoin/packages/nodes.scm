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
(define-module (bitcoin packages nodes)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system cmake)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages boost)
  #:use-module (gnu packages cmake)
  #:use-module (gnu packages golang)
  #:use-module (gnu packages libevent)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages llvm)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages serialization)
  #:use-module (gnu packages python)
  #:use-module (gnu packages sqlite)
  #:use-module (gnu packages upnp)
  #:use-module (bitcoin build go-vendor)
  #:use-module (bitcoin packages rust-crates))

;; Built headless: GUI off and no Qt, unlike upstream Guix's bitcoin-core
;; (qt-build-system, -DBUILD_GUI=ON).  A node channel wants the daemon, not the
;; desktop client; dropping Qt shrinks the closure and removes a reproducibility
;; variable.  Same upstream source -- so the differing recipe, not the version
;; (both are 31.0), is why this derivation has no ci.guix counterpart.  See
;; docs/reproducibility.md.
(define-public bitcoin-core
  (package
    (name "bitcoin-core")
    (version "31.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://bitcoincore.org/bin/bitcoin-core-" version
                           "/bitcoin-" version ".tar.gz"))
       (sha256
        (base32 "1qxkcyq8nwq6sw4qi660z8n8356mqdsf4jvpq5ndkvrsx9gfz80b"))))
    (build-system cmake-build-system)
    (arguments
     (list
      #:configure-flags
      #~(list "-DWITH_ZMQ=ON" "-DBUILD_BENCH=OFF" "-DBUILD_GUI=OFF")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'build 'set-no-git-flag
            ;; Not building from a git checkout.
            (lambda _
              (setenv "BITCOIN_GENBUILD_NO_GIT" "1")))
          (add-before 'check 'set-home
            ;; Tests write to $HOME.
            (lambda _
              (setenv "HOME"
                      (getenv "TMPDIR"))))
          (add-after 'check 'check-functional
            (lambda _
              (invoke "python3"
                      "./test/functional/test_runner.py"
                      (string-append "--jobs="
                                     (number->string (parallel-job-count)))
                      ;; These two need IPv6 (::1), which build
                      ;; environments and CI containers lack.
                      "--exclude=interface_bitcoin_cli.py"
                      "--exclude=rpc_bind.py --ipv6"))))))
    (native-inputs (list pkg-config python util-linux))
    (inputs (list boost capnproto libevent sqlite zeromq))
    (home-page "https://bitcoincore.org/")
    (synopsis "Bitcoin full-node reference implementation")
    (description
     "Bitcoin Core is the reference implementation of the Bitcoin peer-to-peer
network.  This package provides @command{bitcoind}, the validating node
daemon, together with @command{bitcoin-cli}, @command{bitcoin-tx} and
@command{bitcoin-wallet}.  It is built with descriptor (SQLite) wallet and
ZeroMQ notification support, without the GUI.")
    (license license:expat)))

(define-public bitcoin-knots
  (package
    (name "bitcoin-knots")
    (version "29.3.knots20260508")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/bitcoinknots/bitcoin/releases/download/v"
             version "/bitcoin-" version ".tar.gz"))
       (sha256
        (base32 "0c6nkpavy99ms5c0nzjp5ahm69cmi2hrh36rcmmnybxkrbdfnflf"))))
    (build-system cmake-build-system)
    (arguments
     (list
      #:configure-flags
      #~(list "-DWITH_ZMQ=ON"
              "-DBUILD_BENCH=OFF"
              "-DBUILD_GUI=OFF"
              "-DWITH_BDB=OFF"
              ;; Knots 29.3 applies the BIP110 (RDTS) network upgrade and
              ;; requires an explicit consent choice at configure time.
              ;; RUNTIME_WARN defers the consensus decision to the node
              ;; operator (via the @code{consensusrules=rdts} setting),
              ;; warning hourly until then rather than silently accepting
              ;; the upgrade or refusing to start.
              "-DRDTS_CONSENT=RUNTIME_WARN")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'build 'set-no-git-flag
            (lambda _
              (setenv "BITCOIN_GENBUILD_NO_GIT" "1")))
          (add-before 'check 'set-home
            (lambda _
              (setenv "HOME"
                      (getenv "TMPDIR"))))
          (add-after 'check 'check-functional
            (lambda _
              (invoke "python3"
                      "./test/functional/test_runner.py"
                      (string-append "--jobs="
                                     (number->string (parallel-job-count)))
                      ;; These need IPv6 (::1), which build environments
                      ;; and CI containers lack.  Knots 29's test_runner
                      ;; (unlike Core 31's) takes one comma-separated
                      ;; --exclude and matches exact variant names.
                      (string-append
                       "--exclude=interface_bitcoin_cli.py --descriptors,"
                       "interface_bitcoin_cli.py --legacy-wallet,"
                       "rpc_bind.py --ipv6")))))))
    (native-inputs (list pkg-config python util-linux))
    (inputs (list boost libevent miniupnpc sqlite zeromq))
    (home-page "https://bitcoinknots.org/")
    (synopsis "Bitcoin full-node implementation with extended policy options")
    (description
     "Bitcoin Knots is a derivative of Bitcoin Core offering additional
node-policy configuration options.  This package provides
@command{bitcoind} and companion tools, built with descriptor (SQLite)
wallet and ZeroMQ support, without the GUI or legacy BDB wallet.")
    (license license:expat)))

(define-public btcd
  (let* ((version "0.25.0")
         ;; btcd ships no in-tree vendor/, so dependencies are pulled by the
         ;; fixed-output 'go mod vendor' helper.  This is the resulting nar
         ;; hash; re-harvest it with etc/harvest-fod-hash.sh on version bumps.
         (vendored-hash "074rwlhw3cgjn07q20apm0sndk8alh3z9j42ssxgv5l7l4lgxj2v")
         (plain-source (origin
                         (method git-fetch)
                         (uri (git-reference
                               (url "https://github.com/btcsuite/btcd")
                               (commit (string-append "v" version))))
                         (file-name (git-file-name "btcd" version))
                         (sha256 (base32
                                  "1rrwp2pwfijgkhwqck2i10dmj4593hbwqhxw6hhdqmg2lsm6irxd")))))
    (package
      (name "btcd")
      (version version)
      ;; The source is the plain checkout with a populated vendor/ directory,
      ;; produced by the fixed-output 'go mod vendor' helper (origins compose
      ;; here because computed-file is a valid file-like source).
      (source
       (go-mod-vendored-source #:name "btcd"
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
                ;; No cgo anywhere in the tree; build static, like lnd.
                (setenv "CGO_ENABLED" "0")
                ;; The btcd daemon is the module root (github.com/btcsuite/btcd)
                ;; and btcctl lives under cmd/btcctl.
                (invoke "go"
                        "build"
                        "-o"
                        "btcd-bin/"
                        "."
                        "./cmd/btcctl")))
            (replace 'install
              (lambda _
                (for-each (lambda (f)
                            (install-file f
                                          (string-append #$output "/bin")))
                          '("btcd-bin/btcd" "btcd-bin/btcctl")))))))
      (native-inputs (list go-1.25))
      (home-page "https://github.com/btcsuite/btcd")
      (synopsis "Bitcoin full-node implementation in Go")
      (description
       "btcd is an alternative full-node Bitcoin implementation written in Go.
It downloads, validates and serves the block chain using the same rules as
Bitcoin Core for block acceptance.  This package provides the @command{btcd}
node daemon and the @command{btcctl} RPC client.")
      (license license:isc))))

(define-public floresta
  (package
    (name "floresta")
    (version "0.9.1")
    (source
     ;; Workspace binary (florestad), not published standalone on crates.io,
     ;; so fetch the pinned tag from git rather than a crate-source.  Pre-1.0;
     ;; pin the exact tag.  vinteumorg/Floresta now redirects to getfloresta.
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/getfloresta/Floresta")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0ab1ppr5spcamsdj0d56sm1qn5ccjz23wd57xkhj1j3l2z8c9mz5"))))
    (build-system cargo-build-system)
    (arguments
     (list
      ;; Workspace app: install the daemon and client binaries, not the crate
      ;; sources.  The integration tests drive a running node over the network
      ;; and are not part of the cargo unit suite we build.
      #:install-source? #f
      #:tests? #f
      ;; The workspace root has no [package], so cargo-build-system's default
      ;; `cargo install --path .' install step fails.  Build every workspace
      ;; binary (florestad + floresta-cli) and install them by hand.
      #:cargo-build-flags ''("--release" "--bins")
      #:phases
      #~(modify-phases %standard-phases
          (add-before 'build 'set-build-env
            (lambda _
              ;; aws-lc-sys (via rcgen/tokio-rustls) runs bindgen → libclang.
              (setenv "LIBCLANG_PATH"
                      #$(file-append clang "/lib"))
              ;; The 'bitcoinkernel' feature (on by default, hard-enabled by
              ;; floresta-node) pulls libbitcoinkernel-sys, which compiles
              ;; Bitcoin Core's libbitcoinkernel with CMake; its
              ;; find_package(Boost) needs Boost on CMAKE_PREFIX_PATH.
              (setenv "CMAKE_PREFIX_PATH"
                      #$boost)))
          (replace 'install
            (lambda _
              (let ((bin (string-append #$output "/bin")))
                (install-file "target/release/florestad" bin)
                (install-file "target/release/floresta-cli" bin)))))))
    (native-inputs (list boost clang cmake-minimal pkg-config))
    (inputs (lookup-cargo-inputs 'floresta))
    (home-page "https://github.com/getfloresta/Floresta")
    (synopsis "Lightweight utreexo-based Bitcoin full node in Rust")
    (description
     "Floresta is a lightweight Bitcoin full node built on utreexo, a hash-based
accumulator that lets the node validate the chain without storing the full
UTXO set.  This package provides @command{florestad}, the node daemon with a
built-in Electrum server and watch-only wallet, and @command{floresta-cli},
its JSON-RPC client.")
    ;; Dual-licensed MIT OR Apache-2.0 (LICENSE.md / README; the project ships
    ;; both LICENSE-MIT and LICENSE-APACHE).
    (license (list license:expat license:asl2.0))))
