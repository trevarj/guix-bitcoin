# Examples

Ready-to-run configurations for trying the channel's packages and services.

Start with containers.  They let you run a Bitcoin stack without changing your
host system, and the default explorer example uses regtest so it has data right
away.

## Before You Run

Run commands from the channel checkout root.

`-L .` adds this checkout to Guix's module load path:

```sh
guix build -L . bitcoin-core
```

If you installed the channel in `~/.config/guix/channels.scm` and ran
`guix pull`, drop `-L .`:

```sh
guix build bitcoin-core
```

This channel does not serve substitutes for its own packages.  On a first run,
`bitcoin-core`, `electrs`, and `mempool` build locally from source.

Standard dependencies still come from `ci.guix.gnu.org` unless you pass
`--no-substitutes`.

## Quickstart: Explorer Container

Run the full explorer stack in a throwaway container:

```sh
sudo $(guix system container -L . examples/system-explorer.scm \
         --network \
         --expose=8080)
```

Then open:

```text
http://localhost:8080
```

The example starts:

- `bitcoind` on regtest
- `electrs`
- MariaDB
- nginx
- the mempool.space backend and frontend

On first boot, a one-shot service mines demo blocks and transactions.  The
explorer should have data within seconds after the services finish starting.

Stop the container with `Ctrl-c`.

To keep the regtest chain and database between runs:

```sh
mkdir -p explorer-state

sudo $(guix system container -L . examples/system-explorer.scm \
         --network \
         --expose=8080 \
         --share=$PWD/explorer-state=/var/lib)
```

The seed step is idempotent.  If the chain is already present, it does not mine
a fresh demo chain.

Build time: about 30-60 minutes on a first run, because `bitcoin-core`,
`electrs`, and the `mempool` packages build from source.  Later runs are
near-instant once the packages are in your store.

## Try Packages in a Shell

For a quick command check, use `guix shell`:

```sh
guix shell -L . bitcoin-core -- bitcoind --version
```

To enter a shell with the node and indexer packages:

```sh
guix shell -L . bitcoin-core electrs
```

The `shell-from-source.scm` manifest records the same idea as an example file:

```sh
guix shell -L . -m examples/shell-from-source.scm
```

For a full-source reproducibility demo, add `--pure --no-substitutes`:

```sh
guix shell --pure --no-substitutes -L . -m examples/shell-from-source.scm
```

That builds the whole dependency graph locally.  Expect hours to a day-plus and
tens of GB of store use on the first run.

See [`docs/reproducibility.md`](../docs/reproducibility.md) for what each trust
level proves.

## Build or Check Packages

Build one package:

```sh
guix build -L . bitcoin-core
```

Build the minimal regtest node operating-system:

```sh
guix system build -L . examples/system-node.scm
```

Build the explorer operating-system without running it:

```sh
guix system build -L . examples/system-explorer.scm
```

Verify a package is reproducible against itself:

```sh
./examples/verify-reproducible-build.sh
./examples/verify-reproducible-build.sh electrs
```

The reproducibility script builds the package twice, then re-checks the store
copy.  Budget roughly three full package builds.

## Use a Real System Config

The `system-*.scm` files are normal `operating-system` configs.  They can be
built, run as containers, or adapted into a real Guix System appliance.

For real hardware, edit the placeholder bootloader and root filesystem devices
before reconfiguring.  Containers ignore those fields, but `guix system`
requires them to exist.

To turn the explorer into a networked appliance, edit the network knob in
`examples/system-explorer.scm`:

```scheme
(define %network 'signet)        ; 'regtest | 'signet | 'testnet | 'mainnet
```

Then build and reconfigure:

```sh
guix system build -L . examples/system-explorer.scm
sudo guix system reconfigure -L . examples/system-explorer.scm
```

On signet, testnet, and mainnet, the node syncs from peers and the explorer
fills in as `electrs` indexes.

Keep the UI and Electrum port bound to loopback.  Use SSH tunnels for remote
access:

```sh
ssh -L 8080:127.0.0.1:8080 \
    -L 50001:127.0.0.1:50001 \
    user@host
```

Then use:

```text
explorer: http://localhost:8080
electrs:  127.0.0.1:50001
```

Rough disk needs:

- regtest/signet: a few GB
- testnet: tens of GB
- mainnet: 700GB+

Mainnet needs full blocks, `txindex`, the `electrs` index, and the mempool
database.
