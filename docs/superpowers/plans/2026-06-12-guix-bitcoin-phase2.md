# guix-bitcoin Phase 2 Implementation Plan — Indexers, Wallets, Lightning

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Electrum-server indexers (fulcrum, electrs), wallets (electrum, hwi), Lightning nodes (core-lightning, lnd), and Shepherd services for indexers and Lightning.

**Architecture:** New package modules `btc/packages/{indexers,wallets,lightning}.scm` and service modules `btc/services/{indexers,lightning}.scm`, following the conventions established in phase 1 (copyright header, typed `define-configuration`, cookie auth against the node via the `bitcoin` group, Shepherd ordering). Rust deps use Guix's current `crate-source`/`define-cargo-inputs` idiom in a channel-local `btc/packages/rust-crates.scm`; Go deps use a fixed-output `go mod vendor` origin helper in `btc/build/go-vendor.scm`.

**Tech Stack:** Guix (Guile), cargo-build-system (new cargo-inputs idiom), go toolchain ≥1.25, qmake/C++ (fulcrum), pyproject-build-system (electrum, hwi), custom-configure C build (core-lightning).

**Spec:** `docs/superpowers/specs/2026-06-12-guix-bitcoin-channel-design.md`

**Conventions (same as phase 1):**
- Repo root `/home/trev/Workspace/guix-bitcoin`; load path `-L .`; all commits GPG-signed.
- Every new `.scm` file starts with the copyright header from `btc/packages/libraries.scm`.
- `@HASH@` tokens are the only placeholder; each is resolved in-task via the exact command given.
- **Build verification is DEFERRED** (user decision): tasks verify with `guix repl -L .` module loads and hash computation only. `guix build` checks are queued as separate later tasks. This guix repl reads stdin (no `-e` flag).
- Version facts (verified 2026-06-12): Fulcrum **2.1.1**, electrs **0.11.1** (MSRV Rust 1.85), Electrum **4.7.2**, HWI **3.2.0**, Core Lightning **26.06.1**, lnd **0.20.1-beta** (Go 1.25.5).
- **Sparrow is deferred** (spec slip clause): Java 25 + Gradle + git submodules with no gradle-build-system in Guix; revisit as its own phase.
- Reference for current idioms: local Guix checkout `~/Workspace/guix` (e.g. `gnu/packages/finance.scm` for electrum, `gnu/packages/rust-apps.scm` for `(cargo-inputs …)` usage).

---

### Task 1: `btc/packages/indexers.scm` — fulcrum

**Files:**
- Create: `btc/packages/indexers.scm`

- [ ] **Step 1: Fetch hash**

```bash
git clone --depth 1 --branch v2.1.1 https://github.com/cculianu/Fulcrum /tmp/fulcrum && \
  guix hash -x --serializer=nar /tmp/fulcrum
```

- [ ] **Step 2: Write the module with fulcrum**

```scheme
;;; <copyright header from btc/packages/libraries.scm>
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages indexers)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system cargo)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages databases)
  #:use-module (gnu packages jemalloc)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages qt)
  #:use-module (gnu packages rocksdb)
  #:use-module (btc packages rust-crates))

(define-public fulcrum
  (package
    (name "fulcrum")
    (version "2.1.1")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/cculianu/Fulcrum")
                    (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256 (base32 "@HASH@"))))
    (build-system gnu-build-system)
    (arguments
     (list #:tests? #f                  ;no test suite
           #:phases
           #~(modify-phases %standard-phases
               (replace 'configure
                 (lambda _
                   ;; Use system rocksdb/jemalloc/zlib instead of the
                   ;; bundled static libraries.
                   (invoke "qmake" "Fulcrum.pro"
                           (string-append "PREFIX=" #$output)
                           "LIBS+=-lrocksdb -ljemalloc -lz"
                           "CONFIG+=config_without_bundled_rocksdb"
                           "CONFIG+=config_without_bundled_jemalloc")))
               (replace 'install
                 (lambda _
                   (install-file "Fulcrum"
                                 (string-append #$output "/bin")))))))
    (native-inputs (list pkg-config))
    (inputs (list qtbase-5 rocksdb jemalloc zlib))
    (home-page "https://github.com/cculianu/Fulcrum")
    (synopsis "Fast SPV server for Bitcoin")
    (description
     "Fulcrum is a fast SPV (Electrum protocol) server indexing the Bitcoin
block chain from a trusted full node, serving wallet clients such as
Electrum.")
    (license license:gpl3+)))
```

Note for the implementer: the qmake `CONFIG+=` names for unbundling must be
checked against `Fulcrum.pro` in the source (grep for `rocksdb` in the .pro
file); adjust to the project's actual config knobs — the requirement is
system rocksdb/jemalloc, and `Fulcrum` installed to `bin/`. If Fulcrum 2.x
requires Qt 6, switch `qtbase-5` → `qtbase` and note it.

- [ ] **Step 3: Verify module loads**

```bash
guix repl -L . <<'EOF'
(use-modules (btc packages indexers) (guix packages))
(format #t "~a~%" (package-full-name fulcrum))
EOF
```

Expected: `fulcrum@2.1.1`. (This will fail until Task 2 exists because the
module imports `(btc packages rust-crates)` — either create an empty stub
module in this step, or reorder: do Task 2 Step 1 first. Stub content if
needed: module definition with no body, replaced in Task 2.)

- [ ] **Step 4: Commit**

```bash
git add btc/packages/indexers.scm
git commit -m "packages: add fulcrum

* btc/packages/indexers.scm (fulcrum): New variable."
```

---

### Task 2: `btc/packages/rust-crates.scm` + electrs

**Files:**
- Create: `btc/packages/rust-crates.scm` (channel-local crate table, machine-generated)
- Modify: `btc/packages/indexers.scm` (append electrs)

- [ ] **Step 1: Generate the crate table from electrs's lockfile**

```bash
git clone --depth 1 --branch v0.11.1 https://github.com/romanz/electrs /tmp/electrs
guix import crate --lockfile=/tmp/electrs/Cargo.lock electrs > /tmp/electrs-crates.scm
```

Check `guix import crate --help` for the current lockfile-import flag
spelling (the importer that maintains `gnu/packages/rust-crates.scm`
upstream). Wrap the output into a module:

```scheme
;;; <copyright header>
;;; guix-bitcoin --- channel-local Rust crate sources.
;;; This file is partially machine-generated by 'guix import crate
;;; --lockfile'.  Regenerate per-app entries on version bumps.
(define-module (btc packages rust-crates)
  #:use-module (guix build-system cargo)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:export (lookup-cargo-inputs))

;; <paste generated (define rust-foo-X.Y.Z (crate-source …)) forms here>

(define-cargo-inputs lookup-cargo-inputs
  (electrs => (list <generated crate variables>)))
```

The exact `define-cargo-inputs` interaction with a channel (upstream's
`cargo-inputs` function looks up `(gnu packages rust-crates)`): our module
exports its own `lookup-cargo-inputs`; electrs's package below calls it
directly — do NOT use upstream's `cargo-inputs` helper. Mirror how
`guix/build-system/cargo.scm:85-102` defines them if the generated output
differs.

- [ ] **Step 2: Append electrs to `btc/packages/indexers.scm`**

```scheme
(define-public electrs
  (package
    (name "electrs")
    (version "0.11.1")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/romanz/electrs")
                    (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256 (base32 "@HASH@"))))
    (build-system cargo-build-system)
    (arguments
     (list #:install-source? #f
           #:phases
           #~(modify-phases %standard-phases
               (add-before 'build 'use-system-rocksdb
                 (lambda _
                   ;; Link against Guix's rocksdb instead of building the
                   ;; bundled copy (which needs libclang at build time).
                   (setenv "ROCKSDB_LIB_DIR" #$(file-append rocksdb "/lib"))
                   (setenv "ROCKSDB_INCLUDE_DIR"
                           #$(file-append rocksdb "/include")))))))
    (inputs (cons rocksdb (lookup-cargo-inputs 'electrs)))
    (home-page "https://github.com/romanz/electrs")
    (synopsis "Efficient re-implementation of Electrum Server in Rust")
    (description
     "electrs indexes the Bitcoin block chain served by a trusted full node
and provides the Electrum wallet protocol to clients, with low resource
requirements suitable for personal servers.")
    (license license:expat)))
```

(`guix hash` for the checkout: `guix hash -x --serializer=nar /tmp/electrs`.
If electrs's rocksdb crate version requires the bundled build regardless,
fall back: drop the env phase, add `clang` + `(gnu packages llvm)` import to
native-inputs and note the deviation. Check how the generated crate list
names the lookup — the symbol must match `'electrs`.)

- [ ] **Step 3: Verify both modules load**

```bash
guix repl -L . <<'EOF'
(use-modules (btc packages indexers) (guix packages))
(format #t "~a ~a~%" (package-full-name fulcrum) (package-full-name electrs))
EOF
```

Expected: `fulcrum@2.1.1 electrs@0.11.1`.

- [ ] **Step 4: Commit**

```bash
git add btc/packages/rust-crates.scm btc/packages/indexers.scm
git commit -m "packages: add electrs with channel-local crate table

* btc/packages/rust-crates.scm: New file (machine-generated crate
sources; lookup-cargo-inputs).
* btc/packages/indexers.scm (electrs): New variable."
```

---

### Task 3: `btc/packages/wallets.scm` — electrum + hwi

**Files:**
- Create: `btc/packages/wallets.scm`

- [ ] **Step 1: Study upstream electrum and fetch hashes**

Read `~/Workspace/guix/gnu/packages/finance.scm` — packages `electrum`
(line ~721), `python-electrum-ecc`, `electrum-aionostr`. Upstream is also at
4.7.2; our definition adapts theirs (channel owns the definition; upstream
python dep packages are used as inputs).

```bash
git clone --depth 1 --branch 4.7.2 https://github.com/spesmilo/electrum /tmp/electrum && \
  guix hash -x --serializer=nar /tmp/electrum
git clone --depth 1 --branch 3.2.0 https://github.com/bitcoin-core/HWI /tmp/hwi && \
  guix hash -x --serializer=nar /tmp/hwi
```

- [ ] **Step 2: Write the module**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages wallets)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system pyproject)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages aidc)
  #:use-module (gnu packages check)
  #:use-module (gnu packages finance)
  #:use-module (gnu packages libusb)
  #:use-module (gnu packages python-build)
  #:use-module (gnu packages python-crypto)
  #:use-module (gnu packages python-xyz))

(define-public electrum
  (package
    (name "electrum")
    (version "4.7.2")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/spesmilo/electrum")
                    (commit version)))
              (file-name (git-file-name name version))
              (sha256 (base32 "@HASH@"))))
    (build-system pyproject-build-system)
    ;; Adapt arguments/inputs from upstream Guix's electrum definition
    ;; (gnu/packages/finance.scm): relax-deps phase, set-home phase,
    ;; pytest tests; inputs incl. electrum-aionostr, python-electrum-ecc,
    ;; python-aiorpcx, python-attrs, python-cryptography, python-dnspython,
    ;; python-pyqt-6, python-protobuf, python-qrcode, zbar.  Copy the
    ;; current upstream argument/input lists verbatim, then verify each
    ;; referenced package name exists (guix repl will error otherwise).
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
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/bitcoin-core/HWI")
                    (commit version)))
              (file-name (git-file-name name version))
              (sha256 (base32 "@HASH@"))))
    (build-system pyproject-build-system)
    (arguments
     ;; The test suite drives hardware-wallet simulators that need network
    ;; and vendored firmware; run only the unit-testable subset.
     (list #:tests? #f))
    (native-inputs (list python-poetry-core))
    (inputs (list python-ecdsa python-hidapi python-libusb1 python-mnemonic
                  python-pyaes python-typing-extensions))
    (home-page "https://github.com/bitcoin-core/HWI")
    (synopsis "Hardware wallet interface for Bitcoin")
    (description
     "HWI provides a command-line tool and Python library for interacting
with hardware signing devices (Trezor, Ledger, BitBox, Coldcard, Jade and
others), speaking PSBT to wallet software such as Bitcoin Core.")
    (license license:expat)))
```

The electrum `arguments`/`inputs` comment block is an instruction, not a
placeholder: the implementer copies the live upstream lists from
`~/Workspace/guix/gnu/packages/finance.scm` (they are authoritative and
current at the same version) and resolves any name differences.

- [ ] **Step 3: Verify module loads**

```bash
guix repl -L . <<'EOF'
(use-modules (btc packages wallets) (guix packages))
(format #t "~a ~a~%" (package-full-name electrum) (package-full-name hwi))
EOF
```

Expected: `electrum@4.7.2 hwi@3.2.0`.

- [ ] **Step 4: Commit**

```bash
git add btc/packages/wallets.scm
git commit -m "packages: add wallets module

* btc/packages/wallets.scm (electrum, hwi): New variables.

Sparrow is deferred: Java 25/Gradle with no gradle-build-system in Guix."
```

---

### Task 4: `btc/packages/lightning.scm` — core-lightning + lnd

**Files:**
- Create: `btc/build/go-vendor.scm` (fixed-output go-mod-vendor origin helper)
- Create: `btc/packages/lightning.scm`

- [ ] **Step 1: Write the go vendoring helper**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- fixed-output origins for Go module dependencies.
(define-module (btc build go-vendor)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix modules)
  #:use-module ((guix licenses) #:prefix license:)
  #:export (go-mod-vendored-source))

(define* (go-mod-vendored-source #:key name source hash go)
  "Return a fixed-output derivation producing SOURCE with a populated
vendor/ directory, created by running 'go mod vendor' with network access.
HASH is the expected sha256 (nar, base32 string) of the result."
  (computed-file
   (string-append name "-vendored")
   (with-imported-modules (source-module-closure '((guix build utils)))
     #~(begin
         (use-modules (guix build utils))
         (copy-recursively #$source #$output)
         (setenv "HOME" "/tmp")
         (setenv "GOPATH" "/tmp/go")
         (setenv "GOFLAGS" "-mod=mod")
         (setenv "SSL_CERT_DIR" "/etc/ssl/certs")
         (with-directory-excursion #$output
           (invoke #$(file-append go "/bin/go") "mod" "vendor"))))
   #:options (list #:hash-algo 'sha256
                   #:hash (nix-base32-string->bytevector hash)
                   #:recursive? #t
                   #:env-vars '(("impureEnvVars" .
                                 "http_proxy https_proxy NIX_REMOTE")))))
```

IMPLEMENTER NOTE (this helper is the riskiest piece of phase 2): the exact
`computed-file`/`gexp->derivation` options for fixed-output derivations with
network access must be checked against current Guix (`guix repl`:
`,describe (guix gexp)`; see how `(guix download)` builds fixed-output
derivations, and nonguix/community channels' precedents). Requirements that
must hold whatever the spelling: (a) result is hash-pinned (fixed-output =>
network allowed), (b) `nix-base32-string->bytevector` comes from
`(guix base32)`, (c) the builder has CA certs available (add
`(gnu packages certs)` nss-certs to the gexp's environment if needed —
e.g. `(setenv "SSL_CERT_FILE" #$(file-append nss-certs "/etc/ssl/certs/ca-bundle.crt"))`
with an extra helper parameter). If `computed-file` can't pass
fixed-output options, use `gexp->derivation` via a custom origin `method`
instead — model on how guix builds `cvs-fetch`-style origins. Get the shape
right; the first build check later will validate the hash.

- [ ] **Step 2: Fetch hashes**

```bash
git clone --depth 1 --branch v26.06.1 https://github.com/ElementsProject/lightning /tmp/cln && \
  guix hash -x --serializer=nar /tmp/cln
git clone --depth 1 --branch v0.20.1-beta https://github.com/lightningnetwork/lnd /tmp/lnd && \
  guix hash -x --serializer=nar /tmp/lnd
```

(The vendored-source hash for lnd cannot be precomputed without running the
FOD once; use `(base32 "0000000000000000000000000000000000000000000000000000")`
initially — the deferred build check will print the actual hash to splice in,
same workflow as any Guix FOD. Mark it with a `;; FIXME: real hash from first
build` comment so the build-check task knows.)

- [ ] **Step 3: Write the lightning module**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages lightning)
  #:use-module (guix packages)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages autotools)
  #:use-module (gnu packages golang)
  #:use-module (gnu packages multiprecision)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages python-xyz)
  #:use-module (gnu packages sqlite)
  #:use-module (gnu packages crypto)
  #:use-module (gnu packages compression)
  #:use-module (btc build go-vendor))

(define-public core-lightning
  (package
    (name "core-lightning")
    (version "26.06.1")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/ElementsProject/lightning")
                    (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256 (base32 "@HASH@"))))
    (build-system gnu-build-system)
    (arguments
     (list #:tests? #f                  ;test suite needs running bitcoind
           #:configure-flags
           ;; Rust plugins (cln-grpc, clnrest, …) pull a full cargo tree;
           ;; keep the core daemon pure-C for now.
           #~(list "--disable-rust")
           #:phases
           #~(modify-phases %standard-phases
               ;; Bespoke ./configure rejects standard GNU flags.
               (replace 'configure
                 (lambda* (#:key configure-flags #:allow-other-keys)
                   (setenv "CC" #$(cc-for-target))
                   (apply invoke "./configure"
                          (string-append "--prefix=" #$output)
                          configure-flags))))))
    (native-inputs (list pkg-config python python-mako))
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
  (let ((vendored-hash "0000000000000000000000000000000000000000000000000000"))
    (package
      (name "lnd")
      (version "0.20.1-beta")
      (source (origin
                (method git-fetch)
                (uri (git-reference
                      (url "https://github.com/lightningnetwork/lnd")
                      (commit (string-append "v" version))))
                (file-name (git-file-name name version))
                (sha256 (base32 "@HASH@"))))
      (build-system gnu-build-system)
      (arguments
       (list #:tests? #f
             #:phases
             #~(modify-phases %standard-phases
                 (delete 'configure)
                 (replace 'build
                   (lambda _
                     (setenv "HOME" "/tmp")
                     (setenv "GOFLAGS" "-mod=vendor -trimpath")
                     (setenv "CGO_ENABLED" "0")
                     ;; FIXME: real hash from first build — vendored source
                     ;; replaces the plain checkout once computed.
                     (invoke "go" "build" "-o" "lnd-bin/"
                             "-tags" "autopilotrpc signrpc walletrpc chainrpc invoicesrpc routerrpc watchtowerrpc"
                             "./cmd/lnd" "./cmd/lncli")))
                 (replace 'install
                   (lambda _
                     (for-each (lambda (f)
                                 (install-file f (string-append #$output "/bin")))
                               '("lnd-bin/lnd" "lnd-bin/lncli")))))))
      (native-inputs (list go-1.25))
      (home-page "https://github.com/lightningnetwork/lnd")
      (synopsis "Lightning Network daemon in Go")
      (description
       "lnd is a complete implementation of a Lightning Network node,
providing @command{lnd} and the @command{lncli} command-line tool, with
gRPC and REST interfaces for wallet and channel management.")
      (license license:expat))))
```

IMPLEMENTER NOTES:
- The lnd `source` must become the *vendored* source: wrap the git-fetch
  origin with `go-mod-vendored-source` from `(btc build go-vendor)` —
  e.g. bind the plain origin to a variable and set
  `(source (go-mod-vendored-source #:name "lnd" #:source plain-origin
  #:hash vendored-hash #:go go-1.25))` if origins compose that way, else
  keep the plain source and add a phase copying the vendored tree's
  `vendor/` in. Choose whichever composes cleanly in current Guix and
  document the choice in a comment.
- `go-1.25`: confirm the variable name in `~/Workspace/guix/gnu/packages/golang.scm`
  (could be `go-1.25` or just `go` at ≥1.25). lnd needs ≥1.25.5.
- core-lightning: if `./configure` requires `--disable-valgrind` or
  generated-file tooling beyond mako, follow its `doc/INSTALL.md` from the
  checkout; keep `--disable-rust`.

- [ ] **Step 4: Verify modules load**

```bash
guix repl -L . <<'EOF'
(use-modules (btc packages lightning) (guix packages))
(format #t "~a ~a~%" (package-full-name core-lightning) (package-full-name lnd))
EOF
```

- [ ] **Step 5: Commit**

```bash
git add btc/build/go-vendor.scm btc/packages/lightning.scm
git commit -m "packages: add lightning module

* btc/build/go-vendor.scm: New file (fixed-output go-mod-vendor helper).
* btc/packages/lightning.scm (core-lightning, lnd): New variables."
```

---

### Task 5: `btc/services/indexers.scm`

**Files:**
- Create: `btc/services/indexers.scm`

Follows the exact conventions of `btc/services/bitcoin.scm` (read it first):
typed config, dedicated system users in the `bitcoin` group (for RPC cookie
access), activation creating `/var/lib/<name>` 0750, Shepherd requirement on
`bitcoind`, log to `/var/log/<name>.log`.

- [ ] **Step 1: Write the module**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- Bitcoin ecosystem services for Guix System
(define-module (btc services indexers)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages indexers)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:export (electrs-configuration
            electrs-configuration?
            electrs-service-type
            fulcrum-configuration
            fulcrum-configuration?
            fulcrum-service-type))

;;; electrs

(define-configuration/no-serialization electrs-configuration
  (package
   (file-like electrs)
   "The electrs package to run.")
  (network
   (symbol 'mainnet)
   "Chain: @code{'mainnet}, @code{'testnet}, @code{'signet}, @code{'regtest}.
Must match the bitcoin node's network.")
  (db-directory
   (string "/var/lib/electrs")
   "Directory for the index database.")
  (daemon-data-directory
   (string "/var/lib/bitcoind")
   "The bitcoin node's data directory (for the RPC cookie file).")
  (daemon-rpc-address
   (string "127.0.0.1:8332")
   "host:port of bitcoind's RPC interface.")
  (daemon-p2p-address
   (string "127.0.0.1:8333")
   "host:port of bitcoind's P2P interface.")
  (electrum-rpc-address
   (string "127.0.0.1:50001")
   "host:port for serving the Electrum protocol.")
  (extra-options
   (list-of-strings '())
   "Raw additional command-line options passed to electrs."))

(define (electrs-network-option network)
  (match network
    ('mainnet "bitcoin")
    ('testnet "testnet")
    ('signet  "signet")
    ('regtest "regtest")))

(define (electrs-shepherd-service config)
  (match-record config <electrs-configuration>
    (package network db-directory daemon-data-directory
     daemon-rpc-address daemon-p2p-address electrum-rpc-address
     extra-options)
    (list (shepherd-service
           (provision '(electrs))
           (requirement '(bitcoind user-processes networking))
           (documentation "Run the electrs Electrum server.")
           (start #~(make-forkexec-constructor
                     (append
                      (list #$(file-append package "/bin/electrs")
                            (string-append "--network="
                                           #$(electrs-network-option network))
                            (string-append "--db-dir=" #$db-directory)
                            (string-append "--daemon-dir="
                                           #$daemon-data-directory)
                            (string-append "--daemon-rpc-addr="
                                           #$daemon-rpc-address)
                            (string-append "--daemon-p2p-addr="
                                           #$daemon-p2p-address)
                            (string-append "--electrum-rpc-addr="
                                           #$electrum-rpc-address))
                      '#$extra-options)
                     #:user "electrs"
                     #:group "bitcoin"
                     #:log-file "/var/log/electrs.log"))
           (stop #~(make-kill-destructor SIGINT #:grace-period 60))))))

(define (electrs-account config)
  (list (user-account
         (name "electrs")
         (group "bitcoin")
         (system? #t)
         (comment "electrs daemon user")
         (home-directory (electrs-configuration-db-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (electrs-activation config)
  (match-record config <electrs-configuration> (db-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$db-directory)
        (let ((user (getpwnam "electrs")))
          (chown #$db-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$db-directory #o750))))

(define electrs-service-type
  (service-type
   (name 'electrs)
   (extensions
    (list (service-extension shepherd-root-service-type
                             electrs-shepherd-service)
          (service-extension account-service-type electrs-account)
          (service-extension activation-service-type electrs-activation)))
   (default-value (electrs-configuration))
   (description "Run electrs, an Electrum protocol server indexing the
Bitcoin block chain from a local bitcoind.")))

;;; fulcrum

(define-configuration/no-serialization fulcrum-configuration
  (package
   (file-like fulcrum)
   "The fulcrum package to run.")
  (data-directory
   (string "/var/lib/fulcrum")
   "Directory for Fulcrum's database.")
  (bitcoind-rpc
   (string "127.0.0.1:8332")
   "host:port of bitcoind's RPC interface.")
  (rpc-cookie
   (string "/var/lib/bitcoind/.cookie")
   "Path to bitcoind's RPC cookie file (per-network subdirectory for
non-mainnet, e.g. @file{/var/lib/bitcoind/regtest/.cookie}).")
  (tcp-address
   (string "127.0.0.1:50001")
   "host:port for plain-TCP Electrum protocol service.")
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated @file{fulcrum.conf}."))

(define (fulcrum-config-file config)
  (match-record config <fulcrum-configuration>
    (data-directory bitcoind-rpc rpc-cookie tcp-address extra-config)
    (plain-file "fulcrum.conf"
     (string-append
      "datadir = " data-directory "\n"
      "bitcoind = " bitcoind-rpc "\n"
      "rpccookie = " rpc-cookie "\n"
      "tcp = " tcp-address "\n"
      (string-join extra-config "\n" 'suffix)))))

(define (fulcrum-shepherd-service config)
  (match-record config <fulcrum-configuration> (package)
    (let ((conf (fulcrum-config-file config)))
      (list (shepherd-service
             (provision '(fulcrum))
             (requirement '(bitcoind user-processes networking))
             (documentation "Run the Fulcrum Electrum server.")
             (start #~(make-forkexec-constructor
                       (list #$(file-append package "/bin/Fulcrum") #$conf)
                       #:user "fulcrum"
                       #:group "bitcoin"
                       #:log-file "/var/log/fulcrum.log"))
             (stop #~(make-kill-destructor SIGINT #:grace-period 60)))))))

(define (fulcrum-account config)
  (list (user-account
         (name "fulcrum")
         (group "bitcoin")
         (system? #t)
         (comment "Fulcrum daemon user")
         (home-directory (fulcrum-configuration-data-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (fulcrum-activation config)
  (match-record config <fulcrum-configuration> (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "fulcrum")))
          (chown #$data-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define fulcrum-service-type
  (service-type
   (name 'fulcrum)
   (extensions
    (list (service-extension shepherd-root-service-type
                             fulcrum-shepherd-service)
          (service-extension account-service-type fulcrum-account)
          (service-extension activation-service-type fulcrum-activation)))
   (default-value (fulcrum-configuration))
   (description "Run Fulcrum, a fast Electrum protocol server backed by a
local bitcoind.")))
```

Note: both accounts join group `bitcoin` (created by
`bitcoin-node-service-type`) so the RPC cookie (mode 0640, group bitcoin) is
readable. The `bitcoin` group is only defined when the node service is
present — document in the service descriptions that these services expect
`bitcoin-node-service-type` on the same system. electrs flag spellings
(`--db-dir`, `--daemon-dir`, …) must be checked against
`electrs --help`/its `doc/config.md` in the checkout at /tmp/electrs.

- [ ] **Step 2: Verify module loads**

```bash
guix repl -L . <<'EOF'
(use-modules (btc services indexers))
(format #t "~a ~a~%" electrs-service-type fulcrum-service-type)
EOF
```

- [ ] **Step 3: Commit**

```bash
git add btc/services/indexers.scm
git commit -m "services: add electrs and fulcrum service types

* btc/services/indexers.scm: New module."
```

---

### Task 6: `btc/services/lightning.scm`

**Files:**
- Create: `btc/services/lightning.scm`

Same conventions. Key security property (from spec): the services never
handle key material; seeds/macaroons live in the state directory 0750.

- [ ] **Step 1: Write the module**

```scheme
;;; <copyright header>
;;; guix-bitcoin --- Bitcoin ecosystem services for Guix System
(define-module (btc services lightning)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages lightning)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (ice-9 match)
  #:export (clightning-configuration
            clightning-configuration?
            clightning-service-type
            lnd-configuration
            lnd-configuration?
            lnd-service-type))

;;; core-lightning

(define-configuration/no-serialization clightning-configuration
  (package
   (file-like core-lightning)
   "The core-lightning package to run.")
  (network
   (symbol 'bitcoin)
   "Network: @code{'bitcoin} (mainnet), @code{'testnet}, @code{'signet},
@code{'regtest}.  (CLN calls mainnet @code{bitcoin}.)")
  (data-directory
   (string "/var/lib/clightning")
   "Lightning state directory (contains the wallet seed — backed up by the
operator, never touched by this service).")
  (bitcoin-datadir
   (string "/var/lib/bitcoind")
   "bitcoind data directory, for cookie RPC authentication.")
  (alias
   (string "")
   "Optional public node alias.")
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated CLN config file."))

(define (clightning-config-file config)
  (match-record config <clightning-configuration>
    (network data-directory bitcoin-datadir alias extra-config)
    (plain-file "clightning.conf"
     (string-append
      "network=" (symbol->string network) "\n"
      "lightning-dir=" data-directory "\n"
      "bitcoin-datadir=" bitcoin-datadir "\n"
      (if (string-null? alias) "" (string-append "alias=" alias "\n"))
      "log-file=/var/log/clightning.log\n"
      (string-join extra-config "\n" 'suffix)))))

(define (clightning-shepherd-service config)
  (match-record config <clightning-configuration> (package)
    (let ((conf (clightning-config-file config)))
      (list (shepherd-service
             (provision '(clightning lightningd))
             (requirement '(bitcoind user-processes networking))
             (documentation "Run the Core Lightning daemon.")
             (start #~(make-forkexec-constructor
                       (list #$(file-append package "/bin/lightningd")
                             (string-append "--conf=" #$conf))
                       #:user "clightning"
                       #:group "bitcoin"
                       #:log-file "/var/log/clightning.log"))
             (stop #~(make-kill-destructor SIGTERM #:grace-period 60)))))))

(define (clightning-account config)
  (list (user-account
         (name "clightning")
         (group "bitcoin")
         (system? #t)
         (comment "Core Lightning daemon user")
         (home-directory (clightning-configuration-data-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (clightning-activation config)
  (match-record config <clightning-configuration> (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "clightning")))
          (chown #$data-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define clightning-service-type
  (service-type
   (name 'clightning)
   (extensions
    (list (service-extension shepherd-root-service-type
                             clightning-shepherd-service)
          (service-extension account-service-type clightning-account)
          (service-extension activation-service-type
                             clightning-activation)))
   (default-value (clightning-configuration))
   (description "Run Core Lightning (lightningd) against a local bitcoind,
using cookie RPC authentication.")))

;;; lnd

(define-configuration/no-serialization lnd-configuration
  (package
   (file-like lnd)
   "The lnd package to run.")
  (network
   (symbol 'mainnet)
   "Chain: @code{'mainnet}, @code{'testnet}, @code{'signet},
@code{'regtest}.")
  (data-directory
   (string "/var/lib/lnd")
   "lnd state directory (wallet, macaroons; operator-managed secrets).")
  (bitcoind-rpc-host
   (string "127.0.0.1:8332")
   "host:port of bitcoind RPC.")
  (bitcoind-rpc-cookie
   (string "/var/lib/bitcoind/.cookie")
   "Path to bitcoind's cookie file (per-network subdirectory on
non-mainnet networks).")
  (zmq-pub-raw-block
   (string "tcp://127.0.0.1:28332")
   "bitcoind's zmqpubrawblock endpoint (must be enabled on the node).")
  (zmq-pub-raw-tx
   (string "tcp://127.0.0.1:28333")
   "bitcoind's zmqpubrawtx endpoint (must be enabled on the node).")
  (alias
   (string "")
   "Optional public node alias.")
  (extra-config
   (list-of-strings '())
   "Raw lines appended to the generated @file{lnd.conf}."))

(define (lnd-network-option network)
  (match network
    ('mainnet "bitcoin.mainnet=true")
    ('testnet "bitcoin.testnet=true")
    ('signet  "bitcoin.signet=true")
    ('regtest "bitcoin.regtest=true")))

(define (lnd-config-file config)
  (match-record config <lnd-configuration>
    (network data-directory bitcoind-rpc-host bitcoind-rpc-cookie
     zmq-pub-raw-block zmq-pub-raw-tx alias extra-config)
    (plain-file "lnd.conf"
     (string-append
      "[Application Options]\n"
      "lnddir=" data-directory "\n"
      (if (string-null? alias) "" (string-append "alias=" alias "\n"))
      "[Bitcoin]\n"
      "bitcoin.node=bitcoind\n"
      (lnd-network-option network) "\n"
      "[Bitcoind]\n"
      "bitcoind.rpchost=" bitcoind-rpc-host "\n"
      "bitcoind.rpccookie=" bitcoind-rpc-cookie "\n"
      "bitcoind.zmqpubrawblock=" zmq-pub-raw-block "\n"
      "bitcoind.zmqpubrawtx=" zmq-pub-raw-tx "\n"
      (string-join extra-config "\n" 'suffix)))))

(define (lnd-shepherd-service config)
  (match-record config <lnd-configuration> (package)
    (let ((conf (lnd-config-file config)))
      (list (shepherd-service
             (provision '(lnd))
             (requirement '(bitcoind user-processes networking))
             (documentation "Run the lnd Lightning daemon.")
             (start #~(make-forkexec-constructor
                       (list #$(file-append package "/bin/lnd")
                             (string-append "--configfile=" #$conf))
                       #:user "lnd"
                       #:group "bitcoin"
                       #:log-file "/var/log/lnd.log"))
             (stop #~(make-kill-destructor SIGTERM #:grace-period 60)))))))

(define (lnd-account config)
  (list (user-account
         (name "lnd")
         (group "bitcoin")
         (system? #t)
         (comment "lnd daemon user")
         (home-directory (lnd-configuration-data-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (lnd-activation config)
  (match-record config <lnd-configuration> (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "lnd")))
          (chown #$data-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define lnd-service-type
  (service-type
   (name 'lnd)
   (extensions
    (list (service-extension shepherd-root-service-type
                             lnd-shepherd-service)
          (service-extension account-service-type lnd-account)
          (service-extension activation-service-type lnd-activation)))
   (default-value (lnd-configuration))
   (description "Run lnd against a local bitcoind with cookie RPC
authentication and ZMQ block/transaction notifications.")))
```

(CLN config option spellings — `bitcoin-datadir`, `log-file` — and lnd's
cookie option name `bitcoind.rpccookie` must be checked against the
checkouts in /tmp/cln and /tmp/lnd docs; adjust to real option names.)

- [ ] **Step 2: Verify, with the cross-service requirement check**

```bash
guix repl -L . <<'EOF'
(use-modules (btc services lightning) (btc services indexers))
(format #t "ok~%")
EOF
```

- [ ] **Step 3: Commit**

```bash
git add btc/services/lightning.scm
git commit -m "services: add clightning and lnd service types

* btc/services/lightning.scm: New module."
```

---

### Task 7: Integration — example OS, system tests, CI sets

**Files:**
- Modify: `examples/node-os.scm` (add a commented full-stack example)
- Modify: `tests/bitcoin.scm` (add `%test-electrs` exercising node+indexer)
- Modify: `etc/ci-packages.scm` (new sets)

- [ ] **Step 1: Extend `etc/ci-packages.scm`**

```scheme
;; add imports:
;;   (btc packages indexers) (btc packages wallets) (btc packages lightning)
;; add exports and sets:
(define %indexer-packages (list fulcrum electrs))
(define %wallet-packages (list electrum hwi))
(define %lightning-packages (list core-lightning lnd))
;; %all-packages becomes the append of all five sets.
```

Update `etc/ci-build.sh` usage/case with `indexers|wallets|lightning` set
names mapping to the new variables, and extend `.woodpecker/nodes.yml`'s
path list with `btc/packages/indexers.scm`, `btc/packages/lightning.scm`,
`btc/packages/wallets.scm` (heavy pipelines may build these sets via
`PACKAGE_SET`).

- [ ] **Step 2: Add `%test-electrs` to `tests/bitcoin.scm`**

Model on the existing `%test-bitcoin-node` in the same file: an OS with
`bitcoin-node-service-type` (regtest, txindex #t) plus
`electrs-service-type` (network 'regtest, daemon-rpc-address
"127.0.0.1:18443", daemon-p2p-address "127.0.0.1:18444",
electrum-rpc-address "127.0.0.1:50001"); marionette asserts
`wait-for-service 'electrs` and then that TCP port 50001 accepts a
connection within 120s:

```scheme
(test-assert "electrum port accepts connections"
  (marionette-eval
   '(let loop ((tries 60))
      (let ((sock (socket PF_INET SOCK_STREAM 0)))
        (catch #t
          (lambda ()
            (connect sock AF_INET (inet-pton AF_INET "127.0.0.1") 50001)
            (close-port sock)
            #t)
          (lambda _
            (close-port sock)
            (if (zero? tries) #f
                (begin (sleep 2) (loop (- tries 1))))))))
   marionette))
```

Export `%test-electrs`.

- [ ] **Step 3: Append a commented full-stack snippet to `examples/node-os.scm`**

```scheme
;; Full-stack example (uncomment and adapt):
;; (service electrs-service-type
;;          (electrs-configuration
;;           (network 'regtest)
;;           (daemon-rpc-address "127.0.0.1:18443")))
;; (service clightning-service-type
;;          (clightning-configuration (network 'regtest)))
```

- [ ] **Step 4: Verify everything still loads**

```bash
guix repl -L . <<'EOF'
(use-modules (etc ci-packages) (tests bitcoin) (guix packages))
(format #t "~a packages; tests ok~%" (length %all-packages))
EOF
```

Expected: `11 packages; tests ok` (5 phase-1 + fulcrum electrs electrum hwi
core-lightning lnd).

- [ ] **Step 5: Commit**

```bash
git add etc/ci-packages.scm etc/ci-build.sh .woodpecker/nodes.yml \
        tests/bitcoin.scm examples/node-os.scm
git commit -m "Integrate phase 2 packages into CI sets, tests and examples

* etc/ci-packages.scm: New indexer/wallet/lightning sets.
* etc/ci-build.sh, .woodpecker/nodes.yml: Wire new sets.
* tests/bitcoin.scm (%test-electrs): New variable.
* examples/node-os.scm: Document full-stack services."
```

---

### Deferred build checks (queue as tasks, do not run now)
- `guix build -L . fulcrum electrs` (+ fix electrs crate table / rocksdb path)
- `guix build -L . electrum hwi`
- `guix build -L . core-lightning lnd` (lnd: splice real vendored-source hash)
- `guix build -L . -e '(@ (tests bitcoin) %test-electrs)'`
- `guix lint -L .` via `./etc/ci-build.sh lint`
