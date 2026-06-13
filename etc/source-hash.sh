#!/bin/sh
# Recompute a package's source sha256 so you can bump it.
#
# Workflow: edit `version` (and, for commit-pinned packages, `commit`) in the
# package's .scm, run this, and paste the printed base32 hash into `sha256`.
# It introspects the package *as currently defined* and re-fetches its source,
# so it works for git-fetch (clone the tag/commit) and url-fetch (download the
# tarball) sources alike -- no need to hand-construct the URL.
#
#   etc/source-hash.sh <package-name>
set -eu

[ "$#" -eq 1 ] || { echo "usage: source-hash.sh <package-name>" >&2; exit 1; }
name=$1

# Introspect the source method + location.  Script mode (guix repl -- FILE)
# prints no REPL banner; the name comes in via the environment.
script=$(mktemp)
cat > "$script" <<'EOF'
(use-modules (gnu packages) (guix packages) (guix git-download) (ice-9 match))
(let* ((p   (specification->package (getenv "SH_PKG")))
       (src (package-source p))
       (uri (origin-uri src)))
  (if (git-reference? uri)
      (format #t "git ~a ~a~%"
              (git-reference-url uri) (git-reference-commit uri))
      (format #t "url ~a~%" (match uri ((u . _) u) (u u)))))
EOF
info=$(SH_PKG="$name" guix repl -L . -- "$script" 2>/dev/null)
rm -f "$script"
[ -n "$info" ] || { echo "source-hash: could not introspect '$name'" >&2; exit 1; }

# shellcheck disable=SC2086
set -- $info
case "$1" in
    url)
        url=$2
        echo "source-hash: $name url-fetch $url" >&2
        guix download "$url" 2>/dev/null | tail -1
        ;;
    git)
        url=$2; commit=$3
        echo "source-hash: $name git-fetch $url @ $commit" >&2
        dir=$(mktemp -d)
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
        # Fetch the exact tag or commit shallowly (GitHub/Codeberg allow
        # fetching a raw SHA, which '--branch' cannot do).
        git -C "$dir" fetch -q --depth 1 origin "$commit"
        git -C "$dir" checkout -q FETCH_HEAD
        # -x excludes the VCS files, matching how git-fetch origins are hashed.
        guix hash -x --serializer=nar "$dir"
        rm -rf "$dir"
        ;;
    *)
        echo "source-hash: unexpected introspection result: $info" >&2
        exit 1
        ;;
esac
