#!/bin/sh
# Harvest the real fixed-output (FOD) hash for a package whose vendored hash
# is the all-zeros placeholder.
#
# Vendored packages (lnd's Go modules, mempool's npm node_modules) pin a
# content hash that cannot be known until the FOD is built once.  The bump
# workflow is: set the hash to all zeros, build, read the "actual hash" the
# daemon reports, splice it back.  This automates that loop.
#
#   etc/harvest-fod-hash.sh <package>             # print the real hash
#   etc/harvest-fod-hash.sh <package> --fix FILE  # also splice it into FILE
#
# FILE must contain exactly one all-zeros placeholder (the one being bumped).
set -eu

zeros=0000000000000000000000000000000000000000000000000000
pkg=
fix=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --fix) fix=${2:-}; shift 2 ;;
        -*)    echo "harvest-fod-hash: unknown option $1" >&2; exit 1 ;;
        *)     pkg=$1; shift ;;
    esac
done
[ -n "$pkg" ] || { echo "usage: harvest-fod-hash.sh <package> [--fix FILE]" >&2; exit 1; }

out=$(guix build -L . "$pkg" 2>&1 || true)

# The daemon prints "  actual hash:   <base32>" right after a hash mismatch.
actual=$(printf '%s\n' "$out" \
             | sed -n 's/^[[:space:]]*actual hash:[[:space:]]*//p' | head -1)

if [ -z "$actual" ]; then
    if printf '%s\n' "$out" | grep -q '^/gnu/store/.*'"$pkg"; then
        echo "harvest-fod-hash: $pkg already builds; no placeholder to harvest" >&2
        exit 0
    fi
    echo "harvest-fod-hash: no 'actual hash' in the build output for $pkg" >&2
    echo "harvest-fod-hash: last lines were:" >&2
    printf '%s\n' "$out" | tail -15 >&2
    exit 1
fi

echo "$actual"

if [ -n "$fix" ]; then
    [ -f "$fix" ] || { echo "harvest-fod-hash: no such file: $fix" >&2; exit 1; }
    count=$(grep -c "$zeros" "$fix" || true)
    [ "$count" -eq 1 ] || {
        echo "harvest-fod-hash: expected exactly one all-zeros placeholder in $fix, found $count" >&2
        exit 1
    }
    sed -i "s/$zeros/$actual/" "$fix"
    echo "harvest-fod-hash: spliced $actual into $fix" >&2
fi
