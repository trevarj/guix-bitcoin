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
(define-module (bitcoin packages rust-bitcoin)
  #:use-module (guix packages)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (bitcoin packages rust-crates))

(define-public rust-bitcoin
  (package
    (name "rust-bitcoin")
    (version "0.32.100")
    (source
     (crate-source "bitcoin" version
                   "0v0vx5srvby18nqih2b28786yx3jygfpbfk869gjh48i4jci4n1r"))
    (build-system cargo-build-system)
    (arguments
     (list
      ;; The crates.io tarball omits test fixtures (tests/data/*.json),
      ;; so the test suite cannot even compile; build-only.
      #:tests? #f
      #:install-source? #t))
    (inputs (lookup-cargo-inputs 'rust-bitcoin))
    (home-page "https://github.com/rust-bitcoin/rust-bitcoin")
    (synopsis "Rust library for Bitcoin data structures and protocols")
    (description
     "This crate provides de/serialization, parsing and execution of
Bitcoin data structures and network messages: transactions, blocks,
addresses, scripts and PSBTs.")
    (license license:cc0)))

(define-public rust-bitcoin-hashes
  (package
    (name "rust-bitcoin-hashes")
    (version "1.0.0")
    (source
     (crate-source "bitcoin_hashes" version
                   "1c3s8bzrdl9gy78bplagdjsbv1mfvqc17sc2jshzyzkfq2dc4w4g"))
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #t))
    (inputs (lookup-cargo-inputs 'rust-bitcoin-hashes))
    (home-page "https://github.com/rust-bitcoin/rust-bitcoin")
    (synopsis "Hash types used by rust-bitcoin")
    (description
     "This crate provides hash functions and hash types used throughout the
rust-bitcoin ecosystem, with support for @code{no_std} and constant-time
hashing of Bitcoin data structures.")
    (license license:cc0)))

(define-public rust-secp256k1
  (package
    (name "rust-secp256k1")
    (version "0.31.1")
    (source
     (crate-source "secp256k1" version
                   "1cj21h6jjivlwv9nd5a2rny1xvkpcvvwqgva45y8gn627ns82g1c"))
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #t))
    (inputs (lookup-cargo-inputs 'rust-secp256k1))
    (home-page "https://github.com/rust-bitcoin/rust-secp256k1")
    (synopsis "Rust bindings to libsecp256k1")
    (description
     "This crate provides Rust bindings to libsecp256k1, the library used by
Bitcoin Core for elliptic-curve operations on the secp256k1 curve: ECDSA
signing and verification, Schnorr signatures and key management.")
    (license license:cc0)))

(define-public rust-miniscript
  (package
    (name "rust-miniscript")
    (version "13.1.0")
    (source
     (crate-source "miniscript" version
                   "0svjhik0354dp7r8jv7c5xndn487c41lp231jlam0kjhfz1y4dfd"))
    (build-system cargo-build-system)
    (arguments
     (list
      #:install-source? #t))
    (inputs (lookup-cargo-inputs 'rust-miniscript))
    (home-page "https://github.com/rust-bitcoin/rust-miniscript")
    (synopsis "Miniscript: a structured representation of Bitcoin Script")
    (description
     "Miniscript is a language for writing (a subset of) Bitcoin Scripts in a
structured way, enabling analysis, composition, generic signing and more.
This crate provides parsing, satisfaction and analysis of Miniscript
descriptors.")
    (license license:cc0)))

(define-public rust-bdk-wallet
  (package
    (name "rust-bdk-wallet")
    (version "3.0.0")
    (source
     (crate-source "bdk_wallet" version
                   "1vyl64dmdid2cvgwinmjdnsim4ldpzbg2zsvr97kf8kdabww9wv7"))
    (build-system cargo-build-system)
    (arguments
     (list
      ;; The crates.io tarball's test and example targets reference
      ;; fixtures and feature combinations that are not shipped;
      ;; build-only, like rust-bitcoin.
      #:tests? #f
      #:install-source? #t))
    (inputs (lookup-cargo-inputs 'rust-bdk-wallet))
    (home-page "https://github.com/bitcoindevkit/bdk")
    (synopsis "Bitcoin Dev Kit descriptor-based wallet library")
    (description
     "The Bitcoin Dev Kit wallet library provides a high-level, descriptor-based
API for building Bitcoin wallets: address derivation, transaction creation
and signing, coin selection and persistent wallet state.")
    (license (list license:expat license:asl2.0))))
