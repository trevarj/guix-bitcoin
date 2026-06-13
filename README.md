# guix-bitcoin

A GNU Guix channel for the bitcoin ecosystem: nodes, wallets, libraries,
Lightning, indexers, and explorers — built from source, authenticated,
no substitutes.

## Usage

Add to `~/.config/guix/channels.scm`:

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

Then `guix pull`.

## Packages

See `bitcoin/packages/`. Phase 1 ships: libsecp256k1, libsecp256k1-zkp,
univalue, bitcoin-core, bitcoin-knots.

## Services

`bitcoin-node-service-type` in `(bitcoin services bitcoin)` runs bitcoind
(Core or Knots) on Guix System. See module docstrings for fields.
