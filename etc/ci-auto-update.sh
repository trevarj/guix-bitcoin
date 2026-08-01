#!/bin/sh
# Prepare a mechanical package update in the current checkout.
#
# The allowlist is deliberately narrow: each package has an updater-supported
# source and needs only a version/source-hash edit.  Packages requiring upstream
# signature verification, vendored hashes, Rust dependency regeneration, or
# custom binary-release handling stay in the manual monthly report.
set -eu

auto_update_die() {
    echo "ci-auto-update: $*" >&2
    exit 1
}

auto_update_packages() {
    printf '%s\n' \
        libsecp256k1 \
        fulcrum \
        electrum \
        hwi \
        core-lightning
}

auto_update_file() {
    case "$1" in
        libsecp256k1)  echo bitcoin/packages/libraries.scm ;;
        fulcrum)       echo bitcoin/packages/indexers.scm ;;
        electrum|hwi)  echo bitcoin/packages/wallets.scm ;;
        core-lightning) echo bitcoin/packages/lightning.scm ;;
        *) auto_update_die "unsupported package: $1" ;;
    esac
}

auto_update_version() {
    # Every allowlisted definition has a literal version immediately inside
    # its define-public form.  Reading it directly avoids stale Guile compiled
    # module caches immediately after `guix refresh -u` rewrites the source.
    awk -v symbol="$1" '
        $0 == "(define-public " symbol { in_package = 1; next }
        in_package && /^\(define-public / { exit }
        in_package && $1 == "(version" {
            version = $2
            sub(/^"/, "", version)
            sub(/"\)$/, "", version)
            print version
            exit
        }
    ' "$2"
}

case "${1:-}" in
    --list)
        [ "$#" -eq 1 ] || auto_update_die "usage: ci-auto-update.sh --list"
        auto_update_packages
        exit 0
        ;;
    --file)
        [ "$#" -eq 2 ] || auto_update_die "usage: ci-auto-update.sh --file PACKAGE"
        auto_update_file "$2"
        exit 0
        ;;
    --version)
        [ "$#" -eq 2 ] || auto_update_die "usage: ci-auto-update.sh --version PACKAGE"
        auto_update_version "$2" "$(auto_update_file "$2")"
        exit 0
        ;;
    '')
        auto_update_die "usage: ci-auto-update.sh PACKAGE | --list | --file PACKAGE | --version PACKAGE"
        ;;
esac

[ "$#" -eq 1 ] \
    || auto_update_die "usage: ci-auto-update.sh PACKAGE | --list | --file PACKAGE | --version PACKAGE"

auto_update_package=$1
auto_update_package_file=$(auto_update_file "$auto_update_package")
auto_update_guix=${AUTO_UPDATE_GUIX:-guix}

auto_update_root=$(git rev-parse --show-toplevel 2>/dev/null) \
    || auto_update_die "not inside a Git checkout"
cd "$auto_update_root"

git ls-files --error-unmatch "$auto_update_package_file" >/dev/null 2>&1 \
    || auto_update_die "package file is not tracked: $auto_update_package_file"
git diff --quiet \
    || auto_update_die "tracked worktree changes would make the update ambiguous"
git diff --cached --quiet \
    || auto_update_die "staged changes would make the update ambiguous"

auto_update_old_version=$(auto_update_version \
    "$auto_update_package" "$auto_update_package_file")
[ -n "$auto_update_old_version" ] \
    || auto_update_die "could not read $auto_update_package version"

"$auto_update_guix" refresh -L . -u "$auto_update_package"

auto_update_changed_files=$(git diff --name-only)
case "$auto_update_changed_files" in
    '')
        auto_update_changed=false
        auto_update_new_version=$auto_update_old_version
        ;;
    "$auto_update_package_file")
        auto_update_changed=true
        auto_update_new_version=$(auto_update_version \
            "$auto_update_package" "$auto_update_package_file")
        [ -n "$auto_update_new_version" ] \
            || auto_update_die "could not read updated $auto_update_package version"
        [ "$auto_update_new_version" != "$auto_update_old_version" ] \
            || auto_update_die "package file changed without changing its version"
        git diff --check -- "$auto_update_package_file"
        ;;
    *)
        auto_update_die "updater changed unexpected files: $auto_update_changed_files"
        ;;
esac

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "changed=$auto_update_changed"
        echo "file=$auto_update_package_file"
        echo "old_version=$auto_update_old_version"
        echo "new_version=$auto_update_new_version"
    } >> "$GITHUB_OUTPUT"
fi

if [ "$auto_update_changed" = true ]; then
    echo "ci-auto-update: $auto_update_package $auto_update_old_version -> $auto_update_new_version"
else
    echo "ci-auto-update: $auto_update_package $auto_update_old_version is current"
fi
