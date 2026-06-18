#!/bin/sh
# Map changed file paths to ci-build.sh package-set names.
#
# Reads paths from arguments or, if none, from stdin (one per line).
# Prints the distinct set names that the changes affect, space-separated
# on one line.  If anything maps to "all", prints just "all".
#
#   git diff --name-only A B | etc/ci-changed-sets.sh
#   etc/ci-changed-sets.sh bitcoin/packages/nodes.scm
#
# Used by CI to build only the sets a push actually touched.  Keep the
# mapping in sync with etc/ci-build.sh's case statement.
set -eu

sets=""
add() {
    # Append $1 unless already present.
    case " $sets " in
        *" $1 "*) ;;
        *) sets="${sets:+$sets }$1" ;;
    esac
}

if [ "$#" -gt 0 ]; then
    files="$*"
else
    files=$(cat)
fi

for f in $files; do
    case "$f" in
        bitcoin/packages/libraries.scm)   add libs ;;
        bitcoin/packages/nodes.scm)       add nodes ;;
        bitcoin/packages/wallets.scm)     add wallets ;;
        bitcoin/packages/indexers.scm)    add indexers ;;
        bitcoin/packages/lightning.scm)   add lightning ;;
        bitcoin/packages/rust-bitcoin.scm) add rust ;;
        bitcoin/packages/explorers.scm)   add explorers ;;
        # The crate table is shared by electrs (indexers), the rust
        # family, and mempool's rust-gbt (explorers); the FOD helpers and
        # build/set definitions affect everything -- rebuild all.
        bitcoin/packages/rust-crates.scm) add all ;;
        bitcoin/build/*)                  add all ;;
        etc/ci-packages.scm)              add all ;;
        etc/ci-build.sh)                  add all ;;
        etc/ci-changed-sets.sh)           add all ;;
    esac
done

# "all" subsumes every individual set.
case " $sets " in
    *" all "*) echo all ;;
    *) echo "$sets" ;;
esac
