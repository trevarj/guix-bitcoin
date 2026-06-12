#!/bin/sh
# Build a named package set: etc/ci-build.sh {light|nodes|all|lint}
# Used by CI and equally runnable on any build box.
set -eu
set_name="${1:-light}"
case "$set_name" in
  light) var=%light-packages ;;
  nodes) var=%node-packages ;;
  all)   var=%all-packages ;;
  lint)
    names=$(guix repl -L . <<'EOF'
(use-modules (etc ci-packages) (guix packages))
(format #t "~{~a~%~}" (map package-name %all-packages))
EOF
    )
    exec guix lint -L . $names ;;
  *) echo "unknown set: $set_name (want light|nodes|all|lint)" >&2; exit 1 ;;
esac
exec guix build -L . -e "(@ (etc ci-packages) $var)"
