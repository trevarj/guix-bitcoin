#!/bin/sh
# Verify the channel's bitcoin-core (or any named package) builds reproducibly,
# and compare against the public Guix CI where possible.  Run from the channel
# checkout root:
#
#   ./examples/verify-bitcoin-core.sh            # bitcoin-core
#   ./examples/verify-bitcoin-core.sh electrs    # any channel package
#
# See docs/reproducibility.md for the full trust ladder.  Each build is
# expensive (a full from-source compile); expect this to take a while.
set -eu

pkg="${1:-bitcoin-core}"

echo "==> [1/3] Building $pkg twice; fail if outputs differ (self-determinism)"
guix build -L . --rounds=2 --keep-failed "$pkg"

echo "==> [2/3] Re-checking $pkg rebuilds bit-for-bit against the store copy"
guix build -L . --check --keep-failed "$pkg"

echo "==> [3/3] Challenging $pkg against the public Guix CI"
echo "    NOTE: this channel may pin a version Guix proper does not build, so"
echo "    the package itself often reports 'local hash only'.  This step mainly"
echo "    verifies the shared dependency graph (boost, gcc, glibc, ...)."
guix shell diffoscope -- \
  guix challenge "$pkg" \
    --substitute-urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org" \
    --diff=diffoscope || true

echo "==> Done.  Identical hashes across rounds/check mean your build is"
echo "    reproducible; see docs/reproducibility.md for what each step proves."
