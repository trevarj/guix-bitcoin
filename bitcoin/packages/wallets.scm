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
(define-module (bitcoin packages wallets)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix build-system cargo)
  #:use-module (guix build-system pyproject)
  #:use-module (nonguix build-system binary)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (gnu packages aidc)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages check)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages finance)
  #:use-module (gnu packages fontutils)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages libusb)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages protobuf)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-crypto)
  #:use-module (gnu packages python-web)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages qt)
  #:use-module (gnu packages serialization)
  #:use-module (gnu packages sqlite)
  #:use-module (gnu packages xorg)
  #:use-module (bitcoin packages rust-crates))

(define-public electrum
  (package
    (name "electrum")
    (version "4.7.2")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/spesmilo/electrum")
             (commit version)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "05y3w9jhpfxd7frzlilqvsfggrgfzcml2spc2qb5xx9j4q62hnmx"))))
    (build-system pyproject-build-system)
    ;; Arguments and inputs adapted verbatim from upstream Guix's electrum
    ;; (gnu/packages/finance.scm), which is at the same 4.7.2 version.
    (arguments
     (list
      ;; Either pycryptodomex or cryptography must be available.  This package
      ;; uses python-cryptography, but the test checks for cryptodomex anyway.
      #:test-flags
      #~(list "-k" "not test_pycryptodomex_is_available")
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'relax-deps
            (lambda _
              (substitute* "contrib/requirements/requirements.txt"
                (("attrs.*")
                 "attrs")
                (("dnspython.*")
                 "dnspython"))))
          (add-before 'check 'set-home
            (lambda _
              ;; 3 tests run mkdir
              (setenv "HOME" "/tmp"))))))
    (native-inputs (list python-pytest python-setuptools))
    (inputs (list electrum-aionostr
                  python-aiohttp
                  python-aiohttp-socks
                  python-aiorpcx
                  python-attrs
                  python-certifi
                  python-cryptography
                  python-dnspython
                  python-electrum-ecc
                  python-hidapi
                  python-jsonpatch
                  python-protobuf
                  python-pyaes
                  python-pyqt-6
                  python-qdarkstyle
                  python-qrcode
                  zbar))
    (home-page "https://electrum.org/")
    (synopsis "Lightweight Bitcoin wallet")
    (description
     "Electrum is a lightweight Bitcoin client based on a client-server
protocol.  It supports Simple Payment Verification (SPV), deterministic
wallets, hardware wallets and multi-signature setups, without needing to
download the full block chain.")
    (license license:expat)))

(define-public hwi
  (package
    (name "hwi")
    (version "3.2.0")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/bitcoin-core/HWI")
             (commit version)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0k0cwyaldpccl8w9vpr8hcm440y34c1rqhs8rsnzwd47lv96vlxs"))))
    (build-system pyproject-build-system)
    (arguments
     ;; The test suite drives hardware-wallet simulators that need network
     ;; and vendored firmware; run only the unit-testable subset.
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'unpack 'use-poetry-core
            (lambda _
              ;; The old "poetry.masonry.api" backend lives in poetry-core
              ;; as "poetry.core.masonry.api".
              (substitute* "pyproject.toml"
                (("poetry\\.masonry\\.api")
                 "poetry.core.masonry.api")))))))
    (native-inputs (list python-poetry-core))
    ;; Runtime dependencies per HWI's pyproject.toml (the Qt GUI extra and
    ;; its optional pyside2 dependency are not packaged here).
    (inputs (list python-cbor2
                  python-ecdsa
                  python-hidapi
                  python-libusb1
                  python-mnemonic
                  python-noiseprotocol
                  python-protobuf
                  python-pyaes
                  python-pyserial
                  python-semver
                  python-typing-extensions))
    (home-page "https://github.com/bitcoin-core/HWI")
    (synopsis "Hardware wallet interface for Bitcoin")
    (description
     "HWI provides a command-line tool and Python library for interacting
with hardware signing devices (Trezor, Ledger, BitBox, Coldcard, Jade and
others), speaking PSBT to wallet software such as Bitcoin Core.")
    (license license:expat)))

(define-public hal
  (package
    (name "hal")
    (version "0.11.0")
    (source
     ;; Published on crates.io as "hal"; the GitHub "latest release" API
     ;; reports a stale v0.9.3, but v0.11.0 is the real latest tag/release.
     (crate-source "hal" version
                   "12z6ai2s5yb3122pi06c9fdgm0dvq9bjfww48a83midhamnd65c5"))
    (build-system cargo-build-system)
    (arguments
     (list
      ;; Application crate: install the "hal" binary, not the library source.
      #:install-source? #f))
    (inputs (lookup-cargo-inputs 'hal))
    (home-page "https://github.com/stevenroose/hal")
    (synopsis "Bitcoin command-line Swiss-army knife")
    (description
     "hal is a command-line tool to inspect, build and manipulate Bitcoin
data: transactions, addresses, keys (BIP32), BIP39 mnemonics, PSBTs,
Miniscript descriptors and Lightning invoices.  It is built on the
rust-bitcoin and rust-miniscript crate stack.")
    (license license:cc0)))

(define-public bdk-cli
  (package
    (name "bdk-cli")
    (version "3.0.0")
    (source
     ;; Published on crates.io as "bdk-cli"; matches the channel's
     ;; crate-source convention.  Pins an older bdk_wallet (2.1.0) than the
     ;; standalone rust-bdk-wallet library (3.0.0), so its dependency tree is
     ;; vendored from its own lockfile rather than the library package.
     (crate-source "bdk-cli" version
                   "0pm8yqfb3yg2ba8j8kgfg54k32m255df1r54nk32nin5sp6n4kba"))
    (build-system cargo-build-system)
    (arguments
     (list
      ;; Application crate: install the "bdk-cli" binary, not the library
      ;; source.  The crates.io tarball does not ship the integration-test
      ;; fixtures, so build only.
      #:tests? #f
      #:install-source? #f))
    ;; bdk-cli links a binary against system SQLite via bdk_wallet's
    ;; rusqlite/libsqlite3-sys; provide the library (and pkg-config so its
    ;; build script locates it) -- the rust-bdk-wallet library package avoids
    ;; this only because it is built without linking an executable.
    (native-inputs (list pkg-config))
    (inputs (cons sqlite
                  (lookup-cargo-inputs 'bdk-cli)))
    (home-page "https://bitcoindevkit.org")
    (synopsis "Command-line Bitcoin wallet built on the Bitcoin Dev Kit")
    (description
     "bdk-cli is a command-line wallet application and playground built on the
Bitcoin Dev Kit (BDK).  It exposes descriptor-based wallets, address
derivation, transaction creation and signing, and blockchain backends
(Electrum, Esplora, compact-block filters) for experimentation and scripting.")
    (license license:expat)))

;; Sparrow is a JavaFX desktop wallet built with Gradle, requiring JDK 25 +
;; JavaFX 26 and a ~200-artifact Maven closure -- a true source build is
;; blocked on JavaFX 26, which Guix lacks (it ships only 8.202).  Upstream's
;; Linux release is a self-contained jpackage app image (its own jlinked JDK
;; 25 + JavaFX 26 + the app modules), and is reproducible from source from
;; v1.5.0 onwards.  We therefore repackage that binary onto Guix's libraries
;; via (nonguix build-system binary): patch the bundled ELF interpreters and
;; runpaths, and export the GUI/hardware-wallet library closure so the natives
;; Sparrow extracts from its jlink image at runtime resolve.
(define-public sparrow-wallet
  (package
    (name "sparrow-wallet")
    (version "2.5.2")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://github.com/sparrowwallet/sparrow/releases"
                           "/download/" version "/sparrowwallet-" version
                           "-x86_64.tar.gz"))
       (sha256
        (base32 "1h0q14nklm8347yg56l7axygs73lfbcpmnynrnrgi0rzl0sx8fwc"))))
    (build-system binary-build-system)
    (supported-systems (list "x86_64-linux"))
    (arguments
     (list
      ;; Repackage upstream bytes verbatim: only patch interpreters/runpaths,
      ;; never strip or rewrite shebangs.
      #:strip-binaries? #f
      #:patch-shebangs? #f
      #:validate-runpath? #f
      ;; unpack chdirs into the tarball's single top-level "Sparrow/" dir, so
      ;; copy its contents (bin/ + lib/) directly into the output -- the
      ;; launcher then resolves its app relative to exe/../lib/{app,runtime}.
      #:install-plan #~'(("." "./"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'install 'patch-runtime
            (lambda* (#:key inputs outputs #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (ld (search-input-file
                          inputs "/lib/ld-linux-x86-64.so.2"))
                     ;; Resolve native deps from the output's own lib dirs
                     ;; first (sibling .so), then the input closure.
                     (rpath
                      (string-join
                       (append
                        (list (string-append out "/lib")
                              (string-append out "/lib/runtime/lib")
                              (string-append out "/lib/runtime/lib/server"))
                        (filter file-exists?
                                (map (lambda (entry)
                                       (string-append (cdr entry) "/lib"))
                                     inputs)))
                       ":")))
                ;; The only ELF executables (jlink was run with
                ;; --strip-native-commands, so there is no bin/java): the
                ;; outer jpackage launcher and the JVM spawn helper.
                (for-each
                 (lambda (exe)
                   (make-file-writable exe)
                   (invoke "patchelf" "--set-interpreter" ld exe)
                   (invoke "patchelf" "--set-rpath" rpath exe))
                 (list (string-append out "/bin/Sparrow")
                       (string-append out "/lib/runtime/lib/jspawnhelper")))
                ;; Every bundled shared library (JRE + JavaFX natives).
                (for-each
                 (lambda (so)
                   (make-file-writable so)
                   (invoke "patchelf" "--set-rpath" rpath so))
                 (find-files (string-append out "/lib")
                             "\\.so(\\..*)?$")))))
          (add-after 'patch-runtime 'install-entrypoint
            (lambda* (#:key inputs outputs #:allow-other-keys)
              (let* ((out (assoc-ref outputs "out"))
                     (bin (string-append out "/bin"))
                     (bash (search-input-file inputs "/bin/bash"))
                     ;; Natives extracted from the jlink image at runtime
                     ;; (JNA, usb4java, hid4java, jzbar, bwt-jni) cannot be
                     ;; patched, so make their deps findable via the
                     ;; environment instead.
                     (libpath
                      (string-join
                       (filter file-exists?
                               (map (lambda (entry)
                                      (string-append (cdr entry) "/lib"))
                                    inputs))
                       ":")))
                ;; Lowercase `sparrow' launcher on PATH.
                (let ((launcher (string-append bin "/sparrow")))
                  (call-with-output-file launcher
                    (lambda (port)
                      (format port "#!~a
export LD_LIBRARY_PATH=~a${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
exec ~a/bin/Sparrow \"$@\"~%" bash libpath out)))
                  (chmod launcher #o555))
                ;; Desktop integration (no .desktop ships in the tarball).
                (let ((pixmaps (string-append out "/share/pixmaps"))
                      (apps (string-append out "/share/applications"))
                      (mime (string-append out "/share/mime/packages")))
                  (for-each mkdir-p (list pixmaps apps mime))
                  (copy-file (string-append out "/lib/Sparrow.png")
                             (string-append pixmaps "/sparrow.png"))
                  (copy-file (string-append
                              out "/lib/sparrowwallet-Sparrow-MimeInfo.xml")
                             (string-append mime "/sparrow.xml"))
                  (call-with-output-file
                      (string-append apps "/sparrow.desktop")
                    (lambda (port)
                      (format port "[Desktop Entry]
Type=Application
Name=Sparrow Wallet
Comment=Bitcoin wallet focused on security and privacy
Exec=sparrow %u
Icon=sparrow
Terminal=false
Categories=Office;Finance;
MimeType=x-scheme-handler/bitcoin;
StartupWMClass=Sparrow~%")))))))
          ;; The embedded Tor binary lives inside the jlink image and cannot
          ;; be patched; configure Sparrow to use a system Tor proxy instead.
          )))
    (inputs
     (list bash-minimal
           glibc
           (list gcc "lib")
           zlib
           gtk+ glib pango cairo at-spi2-core gdk-pixbuf
           freetype fontconfig
           libx11 libxtst libxxf86vm libxext libxrender libxi libxrandr
           mesa
           libusb hidapi eudev zbar
           alsa-lib))
    (home-page "https://sparrowwallet.com")
    (synopsis "Desktop Bitcoin wallet focused on security and privacy")
    (description
     "Sparrow is a Bitcoin wallet for users who value financial
self-sovereignty: full coin and fee control, PSBT and multi-signature
support, hardware-wallet integration, and a server choice of a private full
node (via Bitcoin Core or an Electrum-protocol server) or a public server.
This package repackages upstream's official, reproducible Linux release image
(a self-contained Java runtime) onto Guix's libraries; its bundled Tor binary
does not run on Guix, so route privacy through an external Tor proxy.")
    (license license:asl2.0)))
