#!/bin/sh
# Install/restore Guix inside a CI container (Debian-based, run as root)
# and start the daemon.  Idempotent: skips anything already present, so a
# cache-restored /gnu + /var/guix means no reinstall and no re-pull.
#
# Usage: etc/ci-setup-guix.sh ensure
#   - installs the Guix binary tarball if /gnu is missing
#   - pulls to the commit pinned in etc/ci-guix-channels.scm if needed
#   - starts guix-daemon and authorizes official substitute servers
set -eu

GUIX_BINARY_VERSION="${GUIX_BINARY_VERSION:-1.4.0}"
GUIX_TARBALL_URL="https://ftp.gnu.org/gnu/guix/guix-binary-${GUIX_BINARY_VERSION}.x86_64-linux.tar.xz"
ROOT_GUIX=/var/guix/profiles/per-user/root/current-guix
PINNED_COMMIT=$(sed -n 's/.*(commit "\([0-9a-f]\{40\}\)").*/\1/p' etc/ci-guix-channels.scm)

say() { printf '\033[1;34m[ci-setup-guix]\033[0m %s\n' "$*"; }

install_binary() {
    say "installing Guix binary tarball ${GUIX_BINARY_VERSION}"
    command -v wget >/dev/null || { apt-get update -qq; apt-get install -y -qq wget xz-utils; }
    command -v xz   >/dev/null || { apt-get update -qq; apt-get install -y -qq xz-utils; }
    wget -q -O /tmp/guix-binary.tar.xz "$GUIX_TARBALL_URL"
    # The tarball contains gnu/ and var/guix at its root.
    rm -rf /tmp/guix-binary; mkdir /tmp/guix-binary
    tar --warning=no-timestamp -xf /tmp/guix-binary.tar.xz -C /tmp/guix-binary
    mv /tmp/guix-binary/gnu /gnu
    mkdir -p /var
    mv /tmp/guix-binary/var/guix /var/guix
    rm -rf /tmp/guix-binary /tmp/guix-binary.tar.xz
}

ensure_users() {
    getent group guixbuild >/dev/null || groupadd --system guixbuild
    for i in $(seq -w 1 10); do
        id "guixbuilder$i" >/dev/null 2>&1 || \
            useradd -g guixbuild -G guixbuild -d /var/empty -s /usr/sbin/nologin \
                    -c "Guix build user $i" --system "guixbuilder$i"
    done
}

start_daemon() {
    if pgrep -f guix-daemon >/dev/null; then
        say "guix-daemon already running"
        return
    fi
    say "starting guix-daemon"
    # --disable-chroot: unprivileged CI containers cannot create the
    # isolated build environment; acceptable for CI verification builds.
    "$ROOT_GUIX/bin/guix-daemon" --build-users-group=guixbuild \
                                 --disable-chroot &
    sleep 1
}

authorize_substitutes() {
    for pub in "$ROOT_GUIX"/share/guix/*.pub; do
        guix archive --authorize < "$pub" || true
    done
}

ensure_path() {
    ln -sf "$ROOT_GUIX/bin/guix" /usr/local/bin/guix
    ln -sf "$ROOT_GUIX/bin/guix-daemon" /usr/local/bin/guix-daemon
    # Make subsequent workflow steps see a pulled guix if present.
    if [ -e /root/.config/guix/current/bin/guix ]; then
        ln -sf /root/.config/guix/current/bin/guix /usr/local/bin/guix
    fi
    if [ -n "${GITHUB_PATH:-}" ]; then
        echo "/usr/local/bin" >> "$GITHUB_PATH"
    fi
}

pull_if_needed() {
    current=$(guix describe -f channels 2>/dev/null | \
              sed -n 's/.*(commit "\([0-9a-f]\{40\}\)").*/\1/p' | head -1 || true)
    if [ "$current" = "$PINNED_COMMIT" ]; then
        say "guix already at pinned commit ${PINNED_COMMIT}"
        return
    fi
    say "guix pull to pinned commit ${PINNED_COMMIT} (one-time; cached afterwards)"
    guix pull -C etc/ci-guix-channels.scm
    ln -sf /root/.config/guix/current/bin/guix /usr/local/bin/guix
    hash -r 2>/dev/null || true
}

case "${1:-ensure}" in
    ensure)
        [ -d /gnu ] && [ -d /var/guix ] || install_binary
        ensure_users
        start_daemon
        ensure_path
        authorize_substitutes
        pull_if_needed
        say "ready: $(guix describe 2>/dev/null | head -1 || echo unknown)"
        ;;
    *)
        echo "usage: $0 ensure" >&2; exit 1 ;;
esac
