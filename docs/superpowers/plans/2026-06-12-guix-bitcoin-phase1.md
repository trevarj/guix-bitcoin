# guix-bitcoin Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working, authenticated Guix channel containing the bitcoin library tier, both node implementations, and a `bitcoin-node-service-type`, verified by builds, lint, and a VM system test.

**Architecture:** A Guix channel rooted at this repo with modules under `(btc packages …)` and `(btc services …)`. Channel authentication uses GPG-signed commits, a `keyring` branch holding the maintainer's public key, and `.guix-authorizations`. Packages are pure source builds; the service is a standard Shepherd service-type with a typed `define-configuration` record.

**Tech Stack:** GNU Guix (Guile Scheme), cmake/gnu build systems, Shepherd, Woodpecker CI (Codeberg), GPG.

**Spec:** `docs/superpowers/specs/2026-06-12-guix-bitcoin-channel-design.md`

**Conventions for every task:**
- All commands run from the repo root `/home/trev/Workspace/guix-bitcoin`.
- All commits MUST be GPG-signed. `git log --show-signature -1` already shows signing works automatically; if a commit ever shows unsigned, re-commit with `git commit -S`.
- Where a step says “paste the hash”, run the given `guix download`/`guix hash` command, copy the base32 sha256 it prints, and replace the `@HASH@` token in the file. `@HASH@` tokens are the ONLY allowed placeholder, and each one is resolved within the same task before building.
- Upstream version facts used below (verified 2026-06-12): Bitcoin Core **31.0**, Bitcoin Knots **29.3.knots20260508**, libsecp256k1 **v0.7.1**, secp256k1-zkp pinned at commit `95b983597af0e5762a1266ede302806883045d22` (project tags no releases).
- Dependency notes: Bitcoin Core ≥30 dropped libevent and the BDB legacy wallet; Core 31 and Knots 29 both build with CMake. Knots 29 still uses libevent. Both use SQLite descriptor wallets. If a configure flag below is rejected by the build, read the package's `cmake -LH` output / release notes and adjust the flag — do not silently drop features (ZMQ, wallet).

---

### Task 1: Channel skeleton and authentication

The channel must authenticate before anything else lands: the commit created in this task becomes the **channel introduction** that every user pins forever.

**Files:**
- Create: `.guix-channel`
- Create: `.guix-authorizations`
- Create: `trevarj.key` (on the `keyring` branch only)
- Modify: `README.md` (create — repo has only `docs/` so far)

- [ ] **Step 1: Write `.guix-channel`**

```scheme
;; -*- scheme -*-
(channel
 (version 0)
 (directory ".")
 (news-file "news.txt"))
```

Also create an empty-but-valid `news.txt`:

```scheme
(channel-news (version 0))
```

- [ ] **Step 2: Write `.guix-authorizations`**

```scheme
;; -*- scheme -*-
(authorizations
 (version 0)
 (("A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758"
   (name "trevarj"))))
```

- [ ] **Step 3: Create the `keyring` branch with the public key**

```bash
git checkout --orphan keyring
git rm -rf --cached . && rm -rf btc docs README.md .guix-channel .guix-authorizations news.txt 2>/dev/null || true
gpg --armor --export A6C20D0C2AD838F949070EA3A52D68794EBED758 > trevarj.key
git add trevarj.key
git commit -m "Add trevarj public key"
git checkout master
```

Expected: `keyring` branch contains exactly one file, `trevarj.key`; `master` is untouched (verify with `git status` → clean except the new skeleton files).

- [ ] **Step 4: Write `README.md`**

```markdown
# guix-bitcoin

A GNU Guix channel for the bitcoin ecosystem: nodes, wallets, libraries,
Lightning, indexers, and explorers — built from source, authenticated,
no substitutes.

## Usage

Add to `~/.config/guix/channels.scm`:

​```scheme
(cons (channel
       (name 'bitcoin)
       (url "https://codeberg.org/trevarj/guix-bitcoin.git")
       (branch "master")
       (introduction
        (make-channel-introduction
         "@INTRO-COMMIT@"
         (openpgp-fingerprint
          "A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758"))))
      %default-channels)
​```

Then `guix pull`.

## Packages

See `btc/packages/`. Phase 1 ships: libsecp256k1, libsecp256k1-zkp,
univalue, bitcoin-core, bitcoin-knots.

## Services

`bitcoin-node-service-type` in `(btc services bitcoin)` runs bitcoind
(Core or Knots) on Guix System. See module docstrings for fields.
```

(`@INTRO-COMMIT@` is resolved in Step 6 of this task. Remove the zero-width
characters around the code fence if your editor kept them — they are only
there to nest the fence in this plan.)

- [ ] **Step 5: Commit the skeleton (this is the channel introduction)**

```bash
git add .guix-channel .guix-authorizations news.txt README.md
git commit -m "channel: add skeleton and authorizations

This commit is the channel introduction."
git log --show-signature -1
```

Expected: `gpg: Good signature from "Trevor Arjeski (trevarj)"`.

- [ ] **Step 6: Record the introduction commit in README**

```bash
INTRO=$(git rev-parse HEAD)
sed -i "s/@INTRO-COMMIT@/$INTRO/" README.md
git add README.md
git commit -m "README: record channel introduction commit"
```

- [ ] **Step 7: Verify authentication end-to-end**

```bash
guix git authenticate "$(git rev-parse HEAD~1)" \
  "A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758"
```

Expected: exits 0, prints nothing or `guix git: successfully authenticated commit …`. If it complains about a missing keyring, the `keyring` branch from Step 3 is missing or misnamed.

---

### Task 2: `btc/packages/libraries.scm`

**Files:**
- Create: `btc/packages/libraries.scm`

- [ ] **Step 1: Fetch source hashes**

```bash
guix download https://github.com/bitcoin-core/secp256k1/archive/refs/tags/v0.7.1.tar.gz
guix download https://github.com/jgarzik/univalue/archive/refs/tags/v1.1.1.tar.gz
git clone --depth 1 https://github.com/BlockstreamResearch/secp256k1-zkp /tmp/zkp \
  && git -C /tmp/zkp fetch --depth 1 origin 95b983597af0e5762a1266ede302806883045d22 \
  && git -C /tmp/zkp checkout 95b983597af0e5762a1266ede302806883045d22 \
  && guix hash -x --serializer=nar /tmp/zkp
```

Each command prints a base32 sha256 — keep all three for Step 2.

- [ ] **Step 2: Write the module**

```scheme
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages libraries)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix build-system cmake)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages autotools))

(define-public libsecp256k1
  (package
    (name "libsecp256k1")
    (version "0.7.1")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://github.com/bitcoin-core/secp256k1/archive/refs/tags/v"
                    version ".tar.gz"))
              (file-name (string-append name "-" version ".tar.gz"))
              (sha256 (base32 "@HASH@"))))
    (build-system cmake-build-system)
    (arguments
     (list #:configure-flags
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
  (let ((commit "95b983597af0e5762a1266ede302806883045d22")
        (revision "0"))
    (package
      (name "libsecp256k1-zkp")
      (version (git-version "0.0" revision commit))
      (source (origin
                (method git-fetch)
                (uri (git-reference
                      (url "https://github.com/BlockstreamResearch/secp256k1-zkp")
                      (commit commit)))
                (file-name (git-file-name name version))
                (sha256 (base32 "@HASH@"))))
      (build-system gnu-build-system)
      (arguments
       (list #:configure-flags
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
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://github.com/jgarzik/univalue/archive/refs/tags/v"
                    version ".tar.gz"))
              (file-name (string-append name "-" version ".tar.gz"))
              (sha256 (base32 "@HASH@"))))
    (build-system gnu-build-system)
    (native-inputs (list autoconf automake libtool))
    (home-page "https://github.com/jgarzik/univalue")
    (synopsis "Universal JSON value class for C++")
    (description
     "UniValue is a small C++ library providing a JSON encoder/decoder and
an abstract value type, used historically by Bitcoin Core and related
tools.")
    (license license:expat)))
```

Replace the three `@HASH@` tokens with the hashes from Step 1 (in order: secp256k1, zkp, univalue).

- [ ] **Step 3: Build all three packages**

```bash
guix build -L . libsecp256k1 libsecp256k1-zkp univalue
```

Expected: three `/gnu/store/…` paths printed. If `libsecp256k1-zkp`'s bootstrap fails, add a `(arguments … #:phases)` note is NOT needed — `gnu-build-system` runs `bootstrap` automatically when `configure` is absent; the autotools native-inputs above cover it. If a `--enable-module-*` flag is rejected, check `./configure --help` in the source and drop only flags that don't exist.

- [ ] **Step 4: Lint**

```bash
guix lint -L . libsecp256k1 libsecp256k1-zkp univalue
```

Expected: no errors; description/synopsis style warnings are fixable inline, CVE warnings are informational.

- [ ] **Step 5: Commit**

```bash
git add btc/packages/libraries.scm
git commit -m "packages: add libraries module

* btc/packages/libraries.scm (libsecp256k1, libsecp256k1-zkp,
univalue): New variables."
```

---

### Task 3: `btc/packages/nodes.scm` — bitcoin-core

**Files:**
- Create: `btc/packages/nodes.scm`

- [ ] **Step 1: Fetch source and verify upstream signatures**

```bash
guix download https://bitcoincore.org/bin/bitcoin-core-31.0/bitcoin-31.0.tar.gz
wget -q -P /tmp https://bitcoincore.org/bin/bitcoin-core-31.0/SHA256SUMS{,.asc}
grep "bitcoin-31.0.tar.gz" /tmp/SHA256SUMS
sha256sum "$(guix download https://bitcoincore.org/bin/bitcoin-core-31.0/bitcoin-31.0.tar.gz 2>/dev/null | tail -1)"
```

Expected: the sha256sum hex digest matches the line in `SHA256SUMS`. (Full builder-key GPG verification of `SHA256SUMS.asc` is documented in CONTRIBUTING.md, Task 7; for the package the content hash pin is what Guix enforces.) Keep the base32 hash from `guix download`.

- [ ] **Step 2: Write the module with bitcoin-core**

```scheme
;;; guix-bitcoin --- Bitcoin ecosystem packages for GNU Guix
(define-module (btc packages nodes)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix build-system cmake)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages boost)
  #:use-module (gnu packages libevent)
  #:use-module (gnu packages networking)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages sqlite))

(define-public bitcoin-core
  (package
    (name "bitcoin-core")
    (version "31.0")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://bitcoincore.org/bin/bitcoin-core-"
                                  version "/bitcoin-" version ".tar.gz"))
              (sha256 (base32 "@HASH@"))))
    (build-system cmake-build-system)
    (arguments
     (list #:configure-flags
           #~(list "-DWITH_ZMQ=ON"
                   "-DBUILD_BENCH=OFF"
                   "-DBUILD_GUI=OFF")
           #:phases
           #~(modify-phases %standard-phases
               (add-before 'check 'set-home
                 (lambda _ (setenv "HOME" "/tmp"))))))
    (native-inputs (list pkg-config python-minimal))
    (inputs (list boost sqlite zeromq))
    (home-page "https://bitcoincore.org/")
    (synopsis "Bitcoin full-node reference implementation")
    (description
     "Bitcoin Core is the reference implementation of the Bitcoin peer-to-peer
network.  This package provides @command{bitcoind}, the validating node
daemon, together with @command{bitcoin-cli}, @command{bitcoin-tx} and
@command{bitcoin-wallet}.  It is built with descriptor (SQLite) wallet and
ZeroMQ notification support, without the GUI.")
    (license license:expat)))
```

Replace `@HASH@` with the base32 hash from Step 1.

- [ ] **Step 3: Build (long — ~30–60 min locally)**

```bash
guix build -L . bitcoin-core
```

Expected: a store path. The `check` phase runs the upstream ctest suite. If CMake rejects a flag (e.g. `BUILD_GUI` renamed), run `tar xf` on the source and check `CMakeLists.txt` option names; fix the flag, never delete the wallet/ZMQ features.

- [ ] **Step 4: Smoke-test the binary**

```bash
$(guix build -L . bitcoin-core)/bin/bitcoind -version | head -2
```

Expected: `Bitcoin Core daemon version v31.0.0` (or similar v31 string).

- [ ] **Step 5: Lint and commit**

```bash
guix lint -L . bitcoin-core
git add btc/packages/nodes.scm
git commit -m "packages: add bitcoin-core

* btc/packages/nodes.scm (bitcoin-core): New variable."
```

---

### Task 4: `btc/packages/nodes.scm` — bitcoin-knots

**Files:**
- Modify: `btc/packages/nodes.scm` (append after `bitcoin-core`)

- [ ] **Step 1: Fetch source hash**

```bash
guix download https://bitcoinknots.org/files/29.x/29.3.knots20260508/bitcoin-29.3.knots20260508.tar.gz
```

- [ ] **Step 2: Append bitcoin-knots to the module**

```scheme
(define-public bitcoin-knots
  (package
    (name "bitcoin-knots")
    (version "29.3.knots20260508")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://bitcoinknots.org/files/29.x/"
                                  version "/bitcoin-" version ".tar.gz"))
              (sha256 (base32 "@HASH@"))))
    (build-system cmake-build-system)
    (arguments
     (list #:configure-flags
           #~(list "-DWITH_ZMQ=ON"
                   "-DBUILD_BENCH=OFF"
                   "-DBUILD_GUI=OFF"
                   "-DWITH_BDB=OFF")
           #:phases
           #~(modify-phases %standard-phases
               (add-before 'check 'set-home
                 (lambda _ (setenv "HOME" "/tmp"))))))
    (native-inputs (list pkg-config python-minimal))
    (inputs (list boost libevent sqlite zeromq))
    (home-page "https://bitcoinknots.org/")
    (synopsis "Bitcoin full-node implementation with extended policy options")
    (description
     "Bitcoin Knots is a derivative of Bitcoin Core offering additional
node-policy configuration options.  This package provides
@command{bitcoind} and companion tools, built with descriptor (SQLite)
wallet and ZeroMQ support, without the GUI or legacy BDB wallet.")
    (license license:expat)))
```

Replace `@HASH@` with the hash from Step 1. Note Knots 29 (unlike Core 31) still links `libevent`, hence the extra input.

- [ ] **Step 3: Build, smoke-test, lint**

```bash
guix build -L . bitcoin-knots
$(guix build -L . bitcoin-knots)/bin/bitcoind -version | head -2
guix lint -L . bitcoin-knots
```

Expected: store path; version string contains `Knots`. If `-DWITH_BDB=OFF` is unrecognized, Knots may name it differently (`-DENABLE_WALLET_BDB=OFF` style) — check `CMakeLists.txt`; the requirement is: no BDB dependency in the closure (`guix size` must not list bdb).

- [ ] **Step 4: Commit**

```bash
git add btc/packages/nodes.scm
git commit -m "packages: add bitcoin-knots

* btc/packages/nodes.scm (bitcoin-knots): New variable."
```

---

### Task 5: `bitcoin-node-service-type`

**Files:**
- Create: `btc/services/bitcoin.scm`
- Create: `examples/node-os.scm` (build-verification fixture, also user documentation)

- [ ] **Step 1: Write the service module**

```scheme
;;; guix-bitcoin --- Bitcoin ecosystem services for Guix System
(define-module (btc services bitcoin)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (btc packages nodes)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (ice-9 match)
  #:export (bitcoin-node-configuration
            bitcoin-node-configuration?
            bitcoin-node-service-type))

(define (string-or-empty? x) (string? x))

(define-configuration/no-serialization bitcoin-node-configuration
  (package
   (file-like bitcoin-core)
   "Node implementation to run: @code{bitcoin-core} or @code{bitcoin-knots}.")
  (network
   (symbol 'mainnet)
   "Chain to use: @code{'mainnet}, @code{'testnet}, @code{'signet} or
@code{'regtest}.")
  (data-directory
   (string "/var/lib/bitcoind")
   "Directory holding the block chain, wallets and RPC cookie.")
  (prune
   (integer 0)
   "Prune target in MiB; @code{0} disables pruning, @code{1} allows manual
pruning.")
  (txindex?
   (boolean #f)
   "Whether to maintain a full transaction index (incompatible with
pruning).")
  (rpc-bind
   (string "127.0.0.1")
   "Address the RPC server listens on.")
  (rpc-auth
   (string "")
   "Optional @code{rpcauth} line (salted hash, as produced by upstream's
@file{share/rpcauth/rpcauth.py}).  When empty, cookie authentication is
used; the cookie is group-readable by the @code{bitcoin} group.")
  (zmq-pub-raw-block
   (string "")
   "Optional ZMQ endpoint for raw block notifications, e.g.
@code{\"tcp://127.0.0.1:28332\"}.")
  (zmq-pub-raw-tx
   (string "")
   "Optional ZMQ endpoint for raw transaction notifications.")
  (extra-config
   (list-of-strings '())
   "Raw lines appended verbatim to @file{bitcoin.conf}."))

(define (network->chain-option network)
  (match network
    ('mainnet "")
    ('testnet "testnet=1\n")
    ('signet  "signet=1\n")
    ('regtest "regtest=1\n")))

(define (network->section network)
  (match network
    ('mainnet "[main]\n")
    ('testnet "[test]\n")
    ('signet  "[signet]\n")
    ('regtest "[regtest]\n")))

(define (bitcoin-node-config-file config)
  (match-record config <bitcoin-node-configuration>
    (network prune txindex? rpc-bind rpc-auth
     zmq-pub-raw-block zmq-pub-raw-tx extra-config)
    (plain-file "bitcoin.conf"
     (string-append
      (network->chain-option network)
      "server=1\n"
      "rpccookieperms=group\n"
      (format #f "prune=~a\n" prune)
      (if txindex? "txindex=1\n" "")
      (if (string-null? rpc-auth) "" (string-append "rpcauth=" rpc-auth "\n"))
      (if (string-null? zmq-pub-raw-block)
          "" (string-append "zmqpubrawblock=" zmq-pub-raw-block "\n"))
      (if (string-null? zmq-pub-raw-tx)
          "" (string-append "zmqpubrawtx=" zmq-pub-raw-tx "\n"))
      (string-join extra-config "\n" 'suffix)
      ;; Per-network section: rpcbind must live here for non-main chains.
      (network->section network)
      (string-append "rpcbind=" rpc-bind "\n")
      (string-append "rpcallowip=" rpc-bind "\n")))))

(define (bitcoin-node-shepherd-service config)
  (match-record config <bitcoin-node-configuration>
    (package data-directory)
    (let ((conf (bitcoin-node-config-file config)))
      (list (shepherd-service
             (provision '(bitcoind bitcoin-node))
             (requirement '(user-processes networking))
             (documentation "Run a bitcoind full node.")
             (start #~(make-forkexec-constructor
                       (list #$(file-append package "/bin/bitcoind")
                             (string-append "-conf=" #$conf)
                             (string-append "-datadir=" #$data-directory))
                       #:user "bitcoin"
                       #:group "bitcoin"
                       #:log-file "/var/log/bitcoind.log"))
             ;; bitcoind flushes state on SIGTERM; give it time.
             (stop #~(make-kill-destructor SIGTERM #:grace-period 120)))))))

(define (bitcoin-node-account config)
  (list (user-group (name "bitcoin") (system? #t))
        (user-account
         (name "bitcoin")
         (group "bitcoin")
         (system? #t)
         (comment "Bitcoin node daemon user")
         (home-directory (bitcoin-node-configuration-data-directory config))
         (create-home-directory? #f)
         (shell (file-append (@ (gnu packages admin) shadow)
                             "/sbin/nologin")))))

(define (bitcoin-node-activation config)
  (match-record config <bitcoin-node-configuration> (data-directory)
    #~(begin
        (use-modules (guix build utils))
        (mkdir-p #$data-directory)
        (let ((user (getpwnam "bitcoin")))
          (chown #$data-directory (passwd:uid user) (passwd:gid user)))
        (chmod #$data-directory #o750))))

(define bitcoin-node-service-type
  (service-type
   (name 'bitcoin-node)
   (extensions
    (list (service-extension shepherd-root-service-type
                             bitcoin-node-shepherd-service)
          (service-extension account-service-type
                             bitcoin-node-account)
          (service-extension activation-service-type
                             bitcoin-node-activation)))
   (default-value (bitcoin-node-configuration))
   (description "Run a Bitcoin full node (Core or Knots) as a Shepherd
service.")))
```

- [ ] **Step 2: Verify the module compiles**

```bash
guix repl -L . <<'EOF'
(use-modules (btc services bitcoin))
(format #t "service-type: ~a~%" bitcoin-node-service-type)
EOF
```

Expected: prints `service-type: #<service-type bitcoin-node …>`. Common failures: `match-record` field order must match definition order; `(@ (gnu packages admin) shadow)` requires no extra import.

- [ ] **Step 3: Write `examples/node-os.scm`**

```scheme
;; Minimal Guix System running a regtest bitcoin node.
;; Build check: guix system build -L . examples/node-os.scm
(use-modules (gnu) (btc services bitcoin) (btc packages nodes))
(use-service-modules base networking ssh)

(operating-system
  (host-name "btc-node")
  (timezone "Etc/UTC")
  (bootloader (bootloader-configuration
               (bootloader grub-bootloader)
               (targets '("/dev/sda"))))
  (file-systems (cons (file-system
                        (mount-point "/")
                        (device "/dev/sda1")
                        (type "ext4"))
                      %base-file-systems))
  (packages (cons bitcoin-core %base-packages))
  (services
   (cons* (service bitcoin-node-service-type
                   (bitcoin-node-configuration
                    (network 'regtest)
                    (zmq-pub-raw-block "tcp://127.0.0.1:28332")))
          %base-services)))
```

- [ ] **Step 4: Build the example system**

```bash
guix system build -L . examples/node-os.scm
```

Expected: a store path for the system derivation (fast — bitcoin-core is already built). This validates config-file generation, accounts, activation, and the Shepherd service gexp.

- [ ] **Step 5: Commit**

```bash
git add btc/services/bitcoin.scm examples/node-os.scm
git commit -m "services: add bitcoin-node-service-type

* btc/services/bitcoin.scm: New module.
* examples/node-os.scm: New example/build fixture."
```

---

### Task 6: System test (marionette VM)

**Files:**
- Create: `tests/bitcoin.scm`

- [ ] **Step 1: Write the system test**

```scheme
;;; guix-bitcoin --- system tests
(define-module (tests bitcoin)
  #:use-module (gnu tests)
  #:use-module (gnu system)
  #:use-module (gnu system vm)
  #:use-module (gnu services)
  #:use-module (btc services bitcoin)
  #:use-module (btc packages nodes)
  #:use-module (guix gexp)
  #:export (%test-bitcoin-node))

(define %bitcoin-node-os
  (simple-operating-system
   (service bitcoin-node-service-type
            (bitcoin-node-configuration
             (network 'regtest)))))

(define (run-bitcoin-node-test)
  (define os
    (marionette-operating-system
     %bitcoin-node-os
     #:imported-modules '((gnu services herd))))
  (define vm (virtual-machine
              (operating-system os)
              (memory-size 1024)))
  (define test
    (with-imported-modules '((gnu build marionette))
      #~(begin
          (use-modules (gnu build marionette) (srfi srfi-64))
          (define marionette (make-marionette (list #$vm)))
          (test-runner-current (system-test-runner #$output))
          (test-begin "bitcoin-node")

          (test-assert "bitcoind service is running"
            (marionette-eval
             '(begin
                (use-modules (gnu services herd))
                (wait-for-service 'bitcoind))
             marionette))

          (test-assert "RPC answers getblockchaininfo"
            (marionette-eval
             '(let loop ((tries 60))
                (let ((status
                       (system* "su" "bitcoin" "-s" "/bin/sh" "-c"
                                (string-append
                                 #$(file-append bitcoin-core "/bin/bitcoin-cli")
                                 " -regtest -datadir=/var/lib/bitcoind"
                                 " getblockchaininfo"))))
                  (cond ((zero? status) #t)
                        ((zero? tries) #f)
                        (else (sleep 2) (loop (- tries 1))))))
             marionette))

          (test-assert "RPC cookie is group-readable"
            (marionette-eval
             '(let ((perms (stat:perms
                            (stat "/var/lib/bitcoind/regtest/.cookie"))))
                (= #o640 (logand perms #o777)))
             marionette))

          (test-end))))
  (gexp->derivation "bitcoin-node-test" test))

(define %test-bitcoin-node
  (system-test
   (name "bitcoin-node")
   (description "Boot a VM with bitcoin-node-service-type on regtest and
exercise the RPC interface.")
   (value (run-bitcoin-node-test))))
```

- [ ] **Step 2: Run the test**

```bash
guix build -L . -e '(@ (tests bitcoin) %test-bitcoin-node)'
```

Expected: derivation builds and the test log (printed on failure, stored on success) shows all three `test-assert`s passing. Debugging notes: if the cookie perms differ, confirm `rpccookieperms=group` survived into the generated `bitcoin.conf` (inspect with `guix build -L . -e '((@ (btc services bitcoin) bitcoin-node-config-file) ((@ (btc services bitcoin) bitcoin-node-configuration)))'` — adjust expression if unexported; exporting `bitcoin-node-config-file` for the test is acceptable).

- [ ] **Step 3: Commit**

```bash
git add tests/bitcoin.scm
git commit -m "tests: add bitcoin-node system test

* tests/bitcoin.scm (%test-bitcoin-node): New variable."
```

---

### Task 7: CI and contributor policy

**Files:**
- Create: `.woodpecker.yml`
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Write `.woodpecker.yml`**

```yaml
# Codeberg Woodpecker CI: verify every channel package builds and lints.
# Requires a runner with KVM disabled-tolerant guix; the metacall/guix
# image ships a ready guix daemon.
steps:
  build:
    image: metacall/guix:latest
    commands:
      - guix describe || true
      - guix build -L . libsecp256k1 libsecp256k1-zkp univalue
      - guix build -L . bitcoin-core bitcoin-knots
      - guix lint -L . libsecp256k1 libsecp256k1-zkp univalue bitcoin-core bitcoin-knots
  authenticate:
    image: metacall/guix:latest
    commands:
      - guix git authenticate "$(git rev-parse "$(git log --reverse --format=%H -- .guix-authorizations | head -1)")" "A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758" || echo "WARN: authentication check needs full clone with keyring branch"
```

Note: runner capabilities (image availability, clone depth, keyring branch fetch) can only be confirmed once the repo is on Codeberg; treat a red `authenticate` step as configuration to fix, not as a blocker for merging packages. The `build` step is the gate.

- [ ] **Step 2: Write `CONTRIBUTING.md`**

```markdown
# Contributing

## Commit policy
- Every commit MUST be GPG-signed by a key listed in `.guix-authorizations`.
- One logical change per commit, GNU ChangeLog-style messages
  (see existing history).

## Version bump checklist
1. Check upstream release announcement and changelog.
2. Download the release tarball; verify the upstream signature:
   - bitcoin-core: verify `SHA256SUMS.asc` against builder keys from
     https://github.com/bitcoin-core/guix.sigs (`builder-keys/`), then
     compare `sha256sum` of the tarball with `SHA256SUMS`.
   - bitcoin-knots: same scheme via
     https://github.com/bitcoinknots/guix.sigs (branch `knots`).
   - libsecp256k1: verify the signed git tag.
3. Update `version` and `sha256` in the package definition.
4. `guix build -L . <package>` and `guix lint -L . <package>`.
5. For service-affecting changes, run the system tests:
   `guix build -L . -e '(@ (tests bitcoin) %test-bitcoin-node)'`.
6. Note the verification performed in the commit message.

## Tier policy
Security-critical packages (libraries, nodes) are full-purity: no vendored
dependency archives. Vendored tiers (rust crates, explorers — later phases)
pin dependency snapshots by hash via helper scripts in `etc/`.
```

- [ ] **Step 3: Commit**

```bash
git add .woodpecker.yml CONTRIBUTING.md
git commit -m "Add CI pipeline and contributor policy"
```

- [ ] **Step 4: End-to-end channel verification (phase 1 acceptance)**

```bash
guix git authenticate "$(git log --reverse --format=%H -- .guix-authorizations | head -1)" \
  "A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758"
guix build -L . libsecp256k1 libsecp256k1-zkp univalue bitcoin-core bitcoin-knots
guix system build -L . examples/node-os.scm
```

Expected: all three commands succeed. Phase 1 is complete and shippable; push `master` and `keyring` branches to Codeberg when ready.
