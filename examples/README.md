# Examples

Ready-to-run configurations built on this channel: `guix system` OS configs,
`guix system container` stacks, and `guix shell` manifests.

## Running examples generically

All commands assume you're at the channel checkout root. `-L .` adds this
checkout to the load path; **if you've installed the channel via
`~/.config/guix/channels.scm`, drop the `-L .`** and the modules resolve
automatically.

```sh
# OS configs (*.scm with an operating-system): build, or reconfigure a machine
guix system build     -L . examples/<file>.scm        # build only (safe check)
sudo guix system reconfigure -L . examples/<file>.scm # apply to THIS machine
guix system vm        -L . examples/<file>.scm         # try it in a throwaway VM

# Container stacks: build a launcher, then run it as root
sudo $(guix system container -L . examples/<file>.scm --network --expose=PORT)

# Shell manifests (*.scm with a manifest): enter an ephemeral environment
guix shell -L . -m examples/<file>.scm
```

> OS configs declare a placeholder `/dev/sda` bootloader/root filesystem so
> `build` and `vm` work out of the box. Edit the device names before
> `reconfigure` on real hardware.

## node-os.scm — minimal regtest node OS

Smallest `guix system` config: a single regtest `bitcoind` with ZMQ enabled.
Starting point for your own node. Inline comments sketch how to bolt on
electrs, Core Lightning, and the mempool stack.

```sh
guix system build -L . examples/node-os.scm
```

## full-node-explorer.scm — self-hosted block explorer appliance

Full (txindex) node + electrs + MariaDB + nginx + mempool.space, as a real OS.
One knob switches the whole stack between networks; everything binds to
loopback.

```sh
# Edit the network, then build:
#   (define %network 'signet)   ; 'signet | 'testnet | 'mainnet
guix system build -L . examples/full-node-explorer.scm
```

After `reconfigure`, the node syncs from real peers and the explorer fills in as
electrs indexes (minutes behind tip on signet, hours on mainnet). Reach the UI
and electrs over SSH rather than exposing them:

```sh
ssh -L 8080:127.0.0.1:8080 -L 50001:127.0.0.1:50001 user@host
# explorer: http://localhost:8080   electrs (e.g. Sparrow): 127.0.0.1:50001
```

Disk: a few GB on signet up to ~700GB+ on mainnet (full blocks + txindex +
electrs index + DB). Size the root device accordingly.

## mempool-container.scm — self-seeding mempool stack (regtest)

The same explorer stack on regtest in a container, with a one-shot that mines a
demo chain (confirmed txs + a live mempool) on first boot — no sync to wait for.

```sh
sudo $(guix system container -L . examples/mempool-container.scm \
         --network --expose=8080)
# then open http://localhost:8080  (blocks appear within seconds)
```

Add `--share=$PWD/mempool-state=/var/lib` to persist the chain across restarts
(the seed is idempotent and skips a non-empty chain).

## reproduce-manifest.scm — from-source node toolset

A `guix shell` manifest (`bitcoin-core` + `electrs`) for reproducibility demos.
Build and enter it trusting no server for any package:

```sh
guix shell --pure --no-substitutes -L . -m examples/reproduce-manifest.scm
```

See `docs/reproducibility.md` for what each trust level proves.

## verify-bitcoin-core.sh — reproducibility check

Builds a channel package twice and re-checks it bit-for-bit (self-determinism).
Each build is a full from-source compile, so expect it to take a while.

```sh
./examples/verify-bitcoin-core.sh            # bitcoin-core (default)
./examples/verify-bitcoin-core.sh electrs    # any channel package
```
