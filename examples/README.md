# Examples

Ready-to-run configurations built on this channel. Files are named
`<format>-<content>`: `system-*` are `guix system` OS configs (also runnable as
containers), `shell-*` are `guix shell` manifests, and scripts are named by what
they do.

## Running examples generically

All commands assume you're at the channel checkout root. `-L .` adds this
checkout to the load path; **if you've installed the channel via
`~/.config/guix/channels.scm`, drop the `-L .`** and the modules resolve
automatically.

```sh
# system-*.scm: build (safe check), reconfigure THIS machine, or try in a VM
guix system build       -L . examples/<file>.scm
sudo guix system reconfigure -L . examples/<file>.scm
guix system vm          -L . examples/<file>.scm

# Any system-*.scm can also run as a throwaway container:
sudo $(guix system container -L . examples/<file>.scm --network --expose=PORT)

# shell-*.scm: enter an ephemeral environment
guix shell -L . -m examples/<file>.scm
```

> OS configs declare a placeholder `/dev/sda` bootloader/root filesystem so
> `build`, `vm`, and `container` work out of the box. Edit the device names
> before `reconfigure` on real hardware (containers ignore them).

**Build times.** This channel serves no substitutes, so its own packages
(`bitcoin-core`, `electrs`, `mempool`) always compile from source; standard
dependencies (MariaDB, nginx, rust/node toolchains) download from
`ci.guix.gnu.org`. The estimates below are for a **first** build on a modern
multi-core x86_64 machine — once a package is in your store, rebuilds are
near-instant. They are *build* times only, separate from blockchain sync. Add
`--no-substitutes` and they jump to hours plus tens of GB (the whole dependency
graph compiles from the bootstrap seed up).

## system-node.scm — minimal node OS

Smallest `guix system` config: a single regtest `bitcoind` with ZMQ enabled.
Starting point for your own node. Inline comments sketch how to bolt on electrs,
Core Lightning, and the mempool stack.

```sh
guix system build -L . examples/system-node.scm
```

Build time: ~10–20 min first time (compiling `bitcoin-core`; base system
substituted), near-instant once cached.

## system-explorer.scm — full node + self-hosted block explorer

Full (txindex) node + electrs + MariaDB + nginx + mempool.space. One knob
(`%network`) switches the whole stack across `regtest`, `signet`, `testnet`, and
`mainnet`; everything binds to loopback. Run it as a real appliance **or** as a
container — it's the same `operating-system`.

**Real appliance** — sync from peers; pick signet/testnet/mainnet:

```sh
# edit the knob:  (define %network 'signet)
guix system build       -L . examples/system-explorer.scm    # check
sudo guix system reconfigure -L . examples/system-explorer.scm
```

The node syncs from peers and the explorer fills in as electrs indexes (minutes
behind tip on signet, hours on mainnet). Reach the UI/electrs over SSH rather
than exposing them:

```sh
ssh -L 8080:127.0.0.1:8080 -L 50001:127.0.0.1:50001 user@host
# explorer: http://localhost:8080   electrs (e.g. Sparrow): 127.0.0.1:50001
```

**Instant demo** — set `(define %network 'regtest)`, then run as a container. A
one-shot mines a demo chain (confirmed txs + a live mempool) on first boot, so
the explorer has data with no sync:

```sh
sudo $(guix system container -L . examples/system-explorer.scm \
         --network --expose=8080)
# then open http://localhost:8080  (blocks appear within seconds)
```

Add `--share=$PWD/explorer-state=/var/lib` to persist the chain across restarts
(the seed is idempotent and skips a non-empty chain).

Build time: ~30–60 min first time — compiles `bitcoin-core`, `electrs`, and the
`mempool` backend/frontend; standard deps substituted. Near-instant once cached.
Independent of `%network` (sync time is not).

Disk (rough): regtest/signet a few GB; testnet tens of GB; mainnet ~700GB+ (full
blocks + txindex + electrs index + the mempool DB). Size the root device
accordingly.

## shell-from-source.scm — from-source node toolset

A `guix shell` manifest (`bitcoin-core` + `electrs`) for reproducibility demos.
Build and enter it trusting no server for any package:

```sh
guix shell --pure --no-substitutes -L . -m examples/shell-from-source.scm
```

Build time: with substitutes for deps, ~20–40 min (compiling `bitcoin-core` +
`electrs`). As shown with `--no-substitutes`, the whole graph builds from the
bootstrap seed: **hours to a day+** and tens of GB of store on first run.

See `docs/reproducibility.md` for what each trust level proves.

## verify-reproducible-build.sh — reproducibility check

Builds a channel package twice and re-checks it bit-for-bit (self-determinism).
Each build is a full from-source compile, so expect it to take a while.

```sh
./examples/verify-reproducible-build.sh            # bitcoin-core (default)
./examples/verify-reproducible-build.sh electrs    # any channel package
```

Build time: builds the package twice (`--rounds=2`) then re-checks it
(`--check`) — budget roughly 3× a single from-source compile (~45–90 min for
`bitcoin-core`, less for `electrs`).
