#!/bin/sh
# Verify the channel's bitcoin-core (or any named package) builds reproducibly.
# Run from the channel checkout root:
#
#   ./examples/verify-reproducible-build.sh            # bitcoin-core
#   ./examples/verify-reproducible-build.sh electrs    # any channel package
#
# Both checks are self-contained (no external reference).  `guix challenge'
# against public servers isn't used: it compares whole derivations, and the
# channel's bitcoin-core derivation differs from upstream Guix's, so there is no
# public counterpart (see docs/reproducibility.md).  Each build is a full
# from-source compile; expect this to take a while.
set -eu

pkg="${1:-bitcoin-core}"

echo "==> [1/2] Building $pkg twice; fail if outputs differ (self-determinism)"
guix build -L . --rounds=2 --keep-failed "$pkg"

echo "==> [2/2] Re-checking $pkg rebuilds bit-for-bit against the store copy"
guix build -L . --check --keep-failed "$pkg"

echo "==> Done.  Identical hashes across both checks mean your build is"
echo "    reproducible; see docs/reproducibility.md for what each step proves."
