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
(define-module (bitcoin packages libraries)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system cmake)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages autotools))

(define-public libsecp256k1
  (package
    (name "libsecp256k1")
    (version "0.7.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/bitcoin-core/secp256k1")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "10cvh8jks3rjg6p7y0vm1v4kw9y7vljbfijj0zxwkxzysxx60w0f"))))
    (build-system cmake-build-system)
    (arguments
     (list
      #:configure-flags
      #~(list "-DSECP256K1_ENABLE_MODULE_RECOVERY=ON"
              "-DSECP256K1_ENABLE_MODULE_ECDH=ON"
              "-DSECP256K1_ENABLE_MODULE_SCHNORRSIG=ON"
              "-DSECP256K1_ENABLE_MODULE_EXTRAKEYS=ON"
              "-DSECP256K1_ENABLE_MODULE_ELLSWIFT=ON"
              "-DSECP256K1_ENABLE_MODULE_MUSIG=ON")))
    (home-page "https://github.com/bitcoin-core/secp256k1")
    (synopsis "Optimized C library for ECDSA signatures on curve secp256k1")
    (description
     "This library implements ECDSA and Schnorr signatures, ECDH, and key
recovery on the secp256k1 elliptic curve, optimized for cryptographic
applications such as Bitcoin.")
    (license license:expat)))

(define-public libsecp256k1-zkp
  ;; No upstream releases; bump commit and increment revision on each update.
  (let ((commit "95b983597af0e5762a1266ede302806883045d22")
        (revision "0"))
    (package
      (name "libsecp256k1-zkp")
      (version (git-version "0.0" revision commit))
      (source
       (origin
         (method git-fetch)
         (uri (git-reference
               (url "https://github.com/BlockstreamResearch/secp256k1-zkp")
               (commit commit)))
         (file-name (git-file-name name version))
         (sha256
          (base32 "13lgc8ag170nnlqvdk211bmra44grp71030v4axwglxn8cc3lrmq"))))
      (build-system gnu-build-system)
      (arguments
       (list
        #:configure-flags
        #~(list "--enable-experimental"
                "--enable-module-recovery"
                "--enable-module-ecdh"
                "--enable-module-schnorrsig"
                "--enable-module-extrakeys"
                "--enable-module-generator"
                "--enable-module-rangeproof"
                "--enable-module-musig"
                "--enable-module-ecdsa-adaptor")))
      (native-inputs (list autoconf automake libtool))
      (home-page "https://github.com/BlockstreamResearch/secp256k1-zkp")
      (synopsis "Fork of libsecp256k1 with zero-knowledge-proof extensions")
      (description
       "This experimental fork of libsecp256k1 adds modules for Pedersen
commitments, range proofs, MuSig, adaptor signatures and other
zero-knowledge-proof building blocks.  Upstream tags no releases, so this
package pins a vetted commit.")
      (license license:expat))))

(define-public univalue
  (package
    (name "univalue")
    (version "1.1.1")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/jgarzik/univalue")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "1yp0xaizfh6j94k9ld9zhz8qxzdf2bb33hc2czhgxf32df9qha7x"))))
    (build-system gnu-build-system)
    (native-inputs (list autoconf automake libtool))
    (home-page "https://github.com/jgarzik/univalue")
    (synopsis "Universal JSON value class for C++")
    (description
     "UniValue is a C++ library providing a universal JSON value type and
encoder/decoder.  It was extracted from Bitcoin Core and remains a dependency
of related Bitcoin tooling.")
    (license license:expat)))
