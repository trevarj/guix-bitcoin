#!/bin/sh
# Build a named package set: etc/ci-build.sh {light|nodes|all}
# Used by CI and equally runnable on any build box.
set -eu
set_name="${1:-light}"
case "$set_name" in
  light) var=%light-packages ;;
  nodes) var=%node-packages ;;
  all)   var=%all-packages ;;
  *) echo "unknown set: $set_name (want light|nodes|all)" >&2; exit 1 ;;
esac
exec guix build -L . -e "(@ (etc ci-packages) $var)"
