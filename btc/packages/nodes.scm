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
(define-module (btc packages nodes)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix build-system cmake)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages boost)
  #:use-module (gnu packages libevent)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages serialization)
  #:use-module (gnu packages python)
  #:use-module (gnu packages sqlite)
  #:use-module (gnu packages upnp))

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
              (invoke "python3" "./test/functional/test_runner.py"
                      (string-append "--jobs="
                                     (number->string (parallel-job-count)))))))))
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
              (invoke "python3" "./test/functional/test_runner.py"
                      (string-append "--jobs="
                                     (number->string (parallel-job-count)))))))))
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
