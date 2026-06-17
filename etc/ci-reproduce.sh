#!/bin/sh
# Reproducibility check + attestation for channel package(s) (default
# bitcoin-core).  Builds each package twice (--rounds=2) and fails if the two
# builds are not bit-for-bit identical, then writes SHA256SUMS listing the
# recursive content hash of every output so independent builders can compare.
# Run from the channel checkout root:
#
#   etc/ci-reproduce.sh                # bitcoin-core
#   etc/ci-reproduce.sh bitcoin-core electrs
#
# The hash is Guix's recursive (nar) sha256 in nix-base32 -- the same content
# hash `guix challenge' compares -- not a plain `sha256sum'.  See
# docs/reproducibility.md.
set -eu

# Resolving a package by name scans every channel module, including
# wallets.scm, which imports (nonguix build-system binary); add the nonguix
# checkout (created by ci-setup-guix.sh) to the load path when present.
NONGUIX_DIR="${NONGUIX_DIR:-/tmp/guix-nonguix}"
nonguix_L=""
[ -d "$NONGUIX_DIR" ] && nonguix_L="-L $NONGUIX_DIR"

[ "$#" -gt 0 ] || set -- bitcoin-core

echo "==> Building twice and checking determinism: $*"
guix build -L . $nonguix_L --rounds=2 --keep-failed "$@"

echo "==> Writing SHA256SUMS (recursive content hash per output)"
: > SHA256SUMS
for p in $(guix build -L . $nonguix_L "$@"); do
  printf '%s  %s\n' "$(guix hash -r "$p")" "$p" >> SHA256SUMS
done
cat SHA256SUMS
echo "==> Reproducible: both rounds matched.  Compare SHA256SUMS with other"
echo "    builders to attest the result (see docs/reproducibility.md)."
