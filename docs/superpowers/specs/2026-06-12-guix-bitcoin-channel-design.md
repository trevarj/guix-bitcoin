# guix-bitcoin Channel — Design

Date: 2026-06-12
Status: Approved

## Goal

A single authenticated Guix channel (`bitcoin`) hosted on Codeberg providing an
up-to-date, source-built catalog of the bitcoin ecosystem — packages and Guix
System services — independent of upstream Guix's often-lagging definitions.

## Decisions

- **Scope (v1):** broad sweep — nodes (Core, Knots), wallets, libraries,
  Lightning, indexers, rust-bitcoin crates, mempool.space.
- **Upstream relationship:** the channel owns every package definition; names
  intentionally shadow upstream Guix (`bitcoin-core` etc.) so manifests read
  naturally and the channel stays fresher than upstream.
- **Purity policy (mixed by tier):** full Guix source purity for the
  security-critical tier (libraries, nodes, core-lightning, fulcrum); pragmatic
  vendoring (cargo-vendor / Go module / npm offline-cache tarballs pinned by
  hash) for rust crates, electrs, lnd, sparrow, and mempool.space. No prebuilt
  binaries anywhere.
- **Distribution & trust:** Codeberg, GPG-signed commits,
  `.guix-authorizations`, published channel introduction; users authenticate
  via `guix pull`.
- **Substitutes:** none. CI verifies every commit builds; users compile
  locally (verify-don't-trust).
- **Structure:** layered monorepo (approach A), implemented in shippable
  phases.

## Repository layout

```
guix-bitcoin/
├── .guix-channel              ; channel metadata: name 'bitcoin', module dir
├── .guix-authorizations       ; authorized signer keys
├── README.md                  ; channel-introduction snippet for channels.scm
├── CONTRIBUTING.md            ; signed-commit policy, bump checklist
├── btc/
│   ├── packages/
│   │   ├── libraries.scm      ; libsecp256k1, libsecp256k1-zkp, univalue
│   │   ├── nodes.scm          ; bitcoin-core, bitcoin-knots
│   │   ├── wallets.scm        ; electrum, hwi, sparrow
│   │   ├── lightning.scm      ; core-lightning, lnd
│   │   ├── indexers.scm       ; fulcrum, electrs
│   │   ├── rust-crates.scm    ; rust-bitcoin, bitcoin_hashes, rust-secp256k1,
│   │   │                      ;   miniscript, bdk
│   │   └── explorers.scm      ; mempool-backend, mempool-frontend
│   └── services/
│       ├── bitcoin.scm        ; bitcoin-node-service-type
│       ├── indexers.scm       ; electrs-/fulcrum-service-type
│       ├── lightning.scm      ; clightning-/lnd-service-type
│       └── mempool.scm        ; mempool-service-type
├── etc/                       ; vendoring helper scripts
├── tests/                     ; system tests (marionette VMs)
└── .woodpecker.yml            ; Codeberg CI
```

Modules live under the `(btc packages …)` / `(btc services …)` namespace.

## Package catalog and tiers

| Module | Packages | Tier |
|---|---|---|
| libraries.scm | libsecp256k1, libsecp256k1-zkp, univalue | Pure |
| nodes.scm | bitcoin-core, bitcoin-knots | Pure |
| wallets.scm | electrum, hwi, sparrow | Pure (sparrow vendored; may slip a phase if Gradle proves hostile) |
| lightning.scm | core-lightning, lnd | Pure / Go-vendored |
| indexers.scm | fulcrum, electrs | Pure / cargo-vendored |
| rust-crates.scm | rust-bitcoin, bitcoin_hashes, rust-secp256k1, miniscript, bdk | Vendored |
| explorers.scm | mempool-backend, mempool-frontend | Vendored (npm) |

Versioning: track upstream releases promptly; one version per tool, except
where Lightning compatibility demands pinning. Release tarball GPG signatures
verified at bump time and noted in the commit message.

## Services design

Conventions for every service: `define-configuration` record with typed,
documented fields; daemon runs as a dedicated unprivileged user; state under
`/var/lib/<name>`; activation creates users/directories; logs to
`/var/log/<name>.log`; ordering via Shepherd requirements (node → indexer →
mempool); bad configurations fail at `guix system` build time.

- **bitcoin-node-service-type** — fields: `package` (default `bitcoin-core`,
  swappable to `bitcoin-knots`), `network` (mainnet/testnet/signet/regtest),
  `data-directory`, `prune`, `txindex?`, `zmq` endpoints, `rpc-bind`,
  `rpc-auth` (rpcauth hash — never plaintext in the store), `extra-config`
  escape hatch. RPC cookie file readable by a `bitcoin` group so dependent
  services authenticate by cookie; no secrets in the world-readable store.
- **electrs-/fulcrum-service-type** — node RPC/cookie path, P2P address,
  index directory, listen address; member of `bitcoin` group; Shepherd
  dependency on the node.
- **clightning-/lnd-service-type** — cookie auth against the node; network,
  alias, listen/announce addresses, `extra-config`. Seeds/macaroons stay in
  the state directory with tight permissions; the service never handles key
  material.
- **mempool-service-type** — composite: Node backend daemon, frontend static
  assets (nginx integration via service extension), MariaDB via extension of
  `mysql-service-type` for schema setup. Depends on the node and an
  electrs/fulcrum instance.

## CI, testing, maintenance

- **CI (Woodpecker):** per push, `guix build -L . <changed packages>` (script
  maps changed modules to packages; full rebuild weekly) plus `guix lint -L .`.
  Dependency substitutes from official Guix CI allowed; channel packages built
  locally.
- **Package tests:** upstream test suites run during build; never disabled
  without documentation.
- **Service tests:** Guix system tests in `tests/` using marionette VMs —
  boot, start service, assert the daemon answers (e.g. `bitcoin-cli -regtest
  getblockchaininfo`); regtest keeps node/lightning/indexer tests fast and
  hermetic.
- **Maintenance:** `guix refresh`-compatible updaters where possible,
  otherwise a manual bump checklist; vendored tarballs regenerated by `etc/`
  helper scripts with output hashes pinned; only `.guix-authorizations` keys
  may land commits.

## Delivery phases (each shippable)

1. Channel skeleton (.guix-channel, authorizations, CI) + libraries.scm +
   nodes.scm + bitcoin-node-service-type.
2. indexers.scm + lightning.scm + wallets.scm + their services.
3. rust-crates.scm.
4. explorers.scm + mempool-service-type.
