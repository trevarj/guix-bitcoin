# Example ideas backlog

Candidate `examples/` to add, for users and demonstration. Brainstormed
2026-06-17; not yet prioritized. Existing examples: `system-node.scm` (minimal
regtest node OS), `system-explorer.scm` (node + electrs + mempool.space stack,
parameterized regtest→mainnet; run as OS or container — built from #3, absorbs
#24's stack and #30's parameterization), `shell-from-source.scm` (from-source
toolset manifest), `verify-reproducible-build.sh` (reproducibility check).

Everything below composes only what the channel + Guix proper already provide
(services: `bitcoin-node`, `clightning`, `lnd`, `electrs`, `fulcrum`,
`mempool`; packages: nodes core/knots/btcd/floresta, wallets
electrum/hwi/hal/bdk-cli/sparrow, indexers, lightning, rust crates).

Complexity is relative to the existing examples. Value = breadth of usefulness /
demo impact (★1–5).

## A. Node operator system configs (`guix system`)

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 1 | Pruned mainnet node + electrs | bitcoin-node, electrs | Canonical "personal node" — private wallet backend | Low | ★★★★★ |
| 2 | Full (txindex) node + Fulcrum | bitcoin-node, fulcrum | High-performance Electrum server | Low | ★★★★ |
| 3 | Signet node + electrs | bitcoin-node, electrs | Try the stack without mainnet sync; pair with Sparrow | Low | ★★★★ | ✅ `system-explorer.scm` (parameterized; +mempool)
| 4 | Tor-only node | bitcoin-node, tor-service-type | Privacy-focused node (onion P2P+RPC) | Med | ★★★★★ |
| 5 | Bitcoin Knots variant | bitcoin-knots | Core→Knots swap; datacarrier/policy config | Low | ★★★ |
| 6 | btcd node OS | btcd | Alternative (Go) full node | Low | ★★ |
| 7 | floresta utreexo node | floresta | Lightweight node (no full UTXO set) | Low | ★★★ |
| 8 | Node appliance disk image | bitcoin-node, electrs, `guix system image` | Flashable image for a dedicated node box | Med | ★★★★ |

## B. Lightning

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 9 | CLN routing node | bitcoin-node, electrs, clightning | Self-hosted Core Lightning node | Med | ★★★★ |
| 10 | LND node | bitcoin-node, lnd | LND with wallet-init notes | Med | ★★★ |
| 11 | Regtest LN playground | bitcoind regtest + 2× CLN/LND | Two nodes auto-open a channel on first boot — LN sandbox | High | ★★★★★ |
| 12 | CLN + LND side by side | clightning, lnd | Comparison / dev | Med | ★★ |
| 13 | Tor-only Lightning node | clightning, tor | Private LN node, onion P2P | Med | ★★★ |

## C. Developer environments (`guix shell` / containers)

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 14 | Regtest dev stack container | bitcoind regtest + electrs (+funded wallet, scripts) | "polar/nigiri"-style app-dev backend | High | ★★★★★ |
| 15 | Bitcoin CLI toolbox `manifest.scm` | bitcoin-core, hal, bdk-cli, electrum | Ephemeral `guix shell -m` dev shell from the channel | Low | ★★★★ |
| 16 | rust-bitcoin dev shell | rust, rust-bitcoin crates, bitcoind | Integration-test env for BDK/rust-bitcoin devs | Med | ★★★ |
| 17 | BDK app dev env | bdk-cli, electrs, regtest node | Descriptor-wallet development loop | Med | ★★★ |
| 18 | LN app dev (regtest + CLN REST/gRPC) | bitcoind, clightning | Build against a local LN node | High | ★★★ |

## D. Desktop / user-level (Guix Home, packages)

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 19 | Bitcoin power-user Home env | sparrow, electrum, hwi, hal, bdk-cli (+HW udev) | Guix Home user profile (no system config) | Med | ★★★★ |
| 20 | Sparrow + personal node | bitcoin-node, electrs + Sparrow | Wire the Sparrow pkg to a private node | Med | ★★★★ |
| 21 | Hardware-wallet workstation | hwi, sparrow, udev rules | HW signing / air-gapped workflow | Med | ★★★ |

## E. Lightweight containers (`guix system container`)

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 22 | Minimal bitcoind regtest container | bitcoin-node | Simplest "spin up a node" | Low | ★★★★ |
| 23 | electrs container | bitcoin-node, electrs | Indexer attached to a node | Low | ★★★ |

## F. Flagship "full stack" demos

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 24 | Sovereign stack OS (signet) | bitcoind + electrs + CLN + mempool | Everything the channel offers, together | High | ★★★★★ |
| 25 | Personal Bitcoin server (mainnet) | bitcoind + fulcrum + mempool + Tor | Production-leaning reference appliance | High | ★★★★ |

## G. Distribution formats

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 26 | Docker image of a node | bitcoin-node, `guix system docker-image` | Run the channel's node on a Docker host | Med | ★★★ |
| 27 | `guix pack` relocatable CLI bundle | bitcoin-core/electrum, `guix pack` | Channel binaries on a non-Guix machine | Med | ★★ |
| 28 | `guix system vm` quick-try | reuse system-node | Try a config in a VM with zero hardware | Low | ★★★ |

## H. Educational / parameterized

| # | Example | Uses | Demonstrates | Cx | Value |
|---|---------|------|--------------|----|----|
| 29 | Teaching regtest container | bitcoind + mempool + scripted txs | Pre-mined chain + narrated transaction scenarios | Med | ★★★ |
| 30 | Network-parameterized node | bitcoin-node | One file, switch mainnet/testnet/signet/regtest | Low | ★★ |

## Suggested first wave

#1 (pruned node + electrs), #3 or #24 (signet single-node / full stack), #11
(regtest LN playground), #15 (toolbox manifest), #19 (Guix Home) — spans
system/container/shell/home formats and node/indexer/lightning/wallet domains.

## Cross-cutting theme: bootstrappability & reproducibility

Investigated 2026-06-17. Goal: how a user can fully bootstrap/verify a node
under Guix, in the spirit of Bitcoin Core's reproducible builds.

Framing: Bitcoin Core's reproducible build (`contrib/guix/` + `guix.sigs`) =
**reproducible + multi-party attested**, but it *trusts* Guix's toolchain
binaries (pins a Guix revision via `guix time-machine`). It is NOT a full-source
bootstrap. Guix can go further: the **full-source bootstrap** roots the whole
package graph in a 357-byte `hex0` seed (+ ~25 MB `guile-bootstrap`),
x86_64/i686 only (2023 milestone). So this channel can offer both the
verify-reproducibility story and a stronger 357-byte-seed trust story.

Trust ladder (least → most paranoid):
- (a) `guix build -L . bitcoin-core` — app from source, deps from ci.guix. mins.
- (b) `guix build -L . --no-substitutes bitcoin-core` — whole dep graph above the
  seed built locally. hours.
- (c) `guix build -L . --rounds=2 --check` — build is deterministic;
  `guix challenge` additionally checks shared deps against public CI.
- (d) `guix build -L . --no-substitutes bitcoin-core` already builds the mesboot
  chain from the 357-byte hex0 source (the graph roots there); only
  guile-bootstrap stays a binary. hours–day+, x86 only.

Caveats: "no substitutes" only stops *us* serving binaries — deps still come
from ci.guix unless the user adds `--no-substitutes`, which then builds the whole
chain (incl. the mesboot toolchain from the hex0 source). `guix challenge`
compares whole derivations, and the channel keeps its own bitcoin-core definition
(both channel and upstream Guix are 31.0, but the derivations differ), so a
public CI counterpart isn't guaranteed — most useful on shared deps. True
multi-party attestation needs >1 builder — the one thing a single channel can't
provide alone.

Candidate artifacts (decide scope):
- `docs/reproducibility.md` — the trust ladder + the three trust layers
  (package / deps / seed) mapped to commands. No blockers.
- `examples/verify-reproducible-build.sh` — `--rounds=2` + `--check` self-determinism
  checks; `guix challenge` doesn't apply (the channel's bitcoin-core derivation
  has no public counterpart).
- `examples/shell-from-source.scm` — node+indexer+wallet manifest +
  `guix shell --pure -m … --no-substitutes` one-liner (overlaps item 15).
- CI reproducibility job — a `--rounds=2`/periodic `--check` job on the `nodes`
  set, making the channel a standing single-party reproducibility attestor
  (gate behind workflow_dispatch; doubles build time).
- Full-source-bootstrap appendix — document-only (`bootstrap-tarballs`,
  `gcc-core-mesboot0`); prohibitive cost, x86 only. Do not wire into CI.
