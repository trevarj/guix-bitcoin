# guix-bitcoin

[![check](https://github.com/trevarj/guix-bitcoin/actions/workflows/check.yml/badge.svg)](https://github.com/trevarj/guix-bitcoin/actions/workflows/check.yml)
[![license: GPL-3.0+](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
[![channel: authenticated](https://img.shields.io/badge/channel-authenticated-success.svg)](#installation)
[![substitutes: build from source](https://img.shields.io/badge/substitutes-build%20from%20source-orange.svg)](#building--substitutes)

A GNU Guix channel for the Bitcoin ecosystem: full nodes, wallets, libraries,
Lightning implementations, Electrum-protocol indexers, and block explorers.
Everything is packaged from upstream source and built locally — the channel is
GPG-authenticated and serves no binary substitutes, so you verify rather than
trust. Guile modules live under the `(bitcoin packages ...)` and
`(bitcoin services ...)` namespaces, with sources in the `bitcoin/` directory.

## Build status

All package sets currently build successfully, both VM system tests pass, and
the example operating system builds. The table reflects verified local builds
as of 2026-06-13. Live per-commit CI (the badge above) runs lint plus the
`light` set on every push; heavier sets build automatically when their files
change, or on demand (see [Building](#building--substitutes)).

| Set         | Packages                                                                 | Status |
|-------------|--------------------------------------------------------------------------|:------:|
| `light`     | libsecp256k1, libsecp256k1-zkp                                            |   ✅   |
| `nodes`     | bitcoin-core, bitcoin-knots                                              |   ✅   |
| `wallets`   | electrum, hwi                                                            |   ✅   |
| `indexers`  | fulcrum, electrs                                                         |   ✅   |
| `lightning` | core-lightning, lnd                                                     |   ✅   |
| `rust`      | rust-bitcoin, rust-bitcoin-hashes, rust-secp256k1, rust-miniscript, rust-bdk-wallet |   ✅   |
| `explorers` | mempool-backend, mempool-frontend (+ mempool-rust-gbt build dep)        |   ✅   |

VM system tests `%test-bitcoin-node` and `%test-electrs` (in
`tests/bitcoin.scm`) pass in a marionette VM, and `examples/node-os.scm` builds
with `guix system build`.

### Package versions

| Package              | Version                  | Set         |
|----------------------|--------------------------|-------------|
| libsecp256k1         | 0.7.1                    | `light`     |
| libsecp256k1-zkp     | commit-pinned            | `light`     |
| bitcoin-core         | 31.0                     | `nodes`     |
| bitcoin-knots        | 29.3.knots20260508       | `nodes`     |
| electrum             | 4.7.2                    | `wallets`   |
| hwi                  | 3.2.0                    | `wallets`   |
| fulcrum              | 2.1.1                    | `indexers`  |
| electrs              | 0.11.1                   | `indexers`  |
| core-lightning       | 26.06.1                  | `lightning` |
| lnd                  | 0.20.1-beta              | `lightning` |
| rust-bitcoin         | 0.32.100                 | `rust`      |
| rust-bitcoin-hashes  | 1.0.0                    | `rust`      |
| rust-secp256k1       | 0.31.1                   | `rust`      |
| rust-miniscript      | 13.1.0                   | `rust`      |
| rust-bdk-wallet      | 3.0.0                    | `rust`      |
| mempool-backend      | 3.3.1                    | `explorers` |
| mempool-frontend     | 3.3.1                    | `explorers` |

## Installation

Add the channel to `~/.config/guix/channels.scm`. The introduction pins the
commit and OpenPGP fingerprint Guix uses to authenticate the channel:

```scheme
(cons (channel
       (name 'bitcoin)
       (url "https://codeberg.org/trevarj/guix-bitcoin.git")
       (branch "master")
       (introduction
        (make-channel-introduction
         "747b9cb83c0f88da46a14638165253b3b0d4b3bc"
         (openpgp-fingerprint
          "A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758"))))
      %default-channels)
```

Then pull:

```sh
guix pull
```

The canonical, authenticated origin is
<https://codeberg.org/trevarj/guix-bitcoin.git>. A GitHub mirror (where CI runs)
is at <https://github.com/trevarj/guix-bitcoin>. Every commit on the channel is
GPG-signed and verified against the fingerprint above when you pull.

## Usage

Install a package directly:

```sh
guix install bitcoin-core
```

### Services

On Guix System, the channel provides service types in `(bitcoin services ...)`:

- `bitcoin-node-service-type` — runs `bitcoind` (Bitcoin Core or Knots) on any
  network, with cookie-based RPC authentication.
- `electrs-service-type` and `fulcrum-service-type` — Electrum-protocol
  indexers that attach to a local node.
- `clightning-service-type` and `lnd-service-type` — Lightning daemons that
  authenticate to the local node via cookie RPC.
- `mempool-service-type` — the mempool.space backend, with MariaDB provisioning
  and an nginx vhost for the frontend.

A minimal node configuration:

```scheme
(use-modules (bitcoin services bitcoin))

(operating-system
  ;; ...
  (services
   (cons* (service bitcoin-node-service-type)
          %base-services)))
```

See [`examples/node-os.scm`](examples/node-os.scm) for a complete, commented
example (node plus optional indexer, Lightning, and explorer services), and the
module docstrings in `bitcoin/services/` for the available configuration fields.

## Building / substitutes

No substitute server is offered for this channel — every package builds from
source on your machine. This is intentional (verify, don't trust). Expect node,
indexer, and Lightning builds to take a while on first install.

You can build any named set locally the same way CI does:

```sh
./etc/ci-build.sh light    # or: nodes indexers wallets lightning rust explorers all
```

CI (`.github/workflows/check.yml`) lints and builds the `light` set on every
push using a cached Guix. Heavier sets build automatically when their files
change: `build-set.yml` maps each changed file to its set
(`etc/ci-changed-sets.sh`) and builds exactly those sets in parallel — e.g. a
commit touching `bitcoin/packages/lightning.scm` builds only the `lightning`
set. You can also dispatch a set on demand:

```sh
gh workflow run build-set.yml -f package_set=nodes
# sets: light | nodes | indexers | wallets | lightning | rust | explorers | all
```

A monthly job (`.github/workflows/refresh.yml`) runs `guix refresh` over the
packages — plus a GitHub Releases check for the node and explorer packages
whose custom download URLs `guix refresh` cannot follow (bitcoin-core,
bitcoin-knots, mempool) — and opens a tracking issue listing what is outdated.
Run it any time with `gh workflow run refresh.yml`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) for the full text; the package and
service modules each carry the GNU GPL v3-or-later header.
