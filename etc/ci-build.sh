#!/bin/sh
# Build a named package set:
#   etc/ci-build.sh {light|nodes|indexers|wallets|lightning|rust|explorers|all|lint}
# Used by CI and equally runnable on any build box.
set -eu
set_name="${1:-light}"

# sparrow-wallet (in bitcoin/packages/wallets.scm, imported transitively by
# (etc ci-packages)) needs (nonguix build-system binary).  ci-setup-guix.sh
# checks nonguix out at NONGUIX_DIR; add it to the load path when present.
# Locally, where nonguix is part of the pulled guix, the directory is absent
# and this stays empty.
NONGUIX_DIR="${NONGUIX_DIR:-/tmp/guix-nonguix}"
nonguix_L=""
[ -d "$NONGUIX_DIR" ] && nonguix_L="-L $NONGUIX_DIR"

case "$set_name" in
  light) var=%light-packages ;;
  nodes) var=%node-packages ;;
  indexers) var=%indexer-packages ;;
  wallets)  var=%wallet-packages ;;
  lightning) var=%lightning-packages ;;
  rust)  var=%rust-packages ;;
  explorers) var=%explorer-packages ;;
  all)   var=%all-packages ;;
  lint)
    # Script mode (guix repl -- FILE) prints no banner, unlike a heredoc
    # REPL, whose banner would end up in $names.
    script=$(mktemp)
    cat > "$script" <<'EOF'
(use-modules (etc ci-packages) (guix packages))
(format #t "~{~a~%~}" (map package-name %all-packages))
EOF
    names=$(guix repl -L . $nonguix_L -- "$script")
    rm -f "$script"
    exec guix lint -L . $nonguix_L $names ;;
  *) echo "unknown set: $set_name (want light|nodes|indexers|wallets|lightning|rust|explorers|all|lint)" >&2; exit 1 ;;
esac
exec guix build -L . $nonguix_L -e "(@ (etc ci-packages) $var)"
