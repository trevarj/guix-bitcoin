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

# Recent nightly binary tarball from Guix CI (commit f4ee072, 2026-06-01):
# the 1.4.0 release tarball is too old to `guix pull' to a current master
# commit (compute-guix-derivation crashes across the 4-year jump).  The
# pinned product URL can be garbage-collected by Cuirass eventually, so
# fall back to resolving the latest successful nightly dynamically.
GUIX_TARBALL_URL="${GUIX_TARBALL_URL:-https://ci.guix.gnu.org/download/3871}"

latest_tarball_url() {
    build=$(wget -qO- "https://ci.guix.gnu.org/api/latestbuilds?nr=1&jobset=tarball&job=binary-tarball.x86_64-linux&status=0" \
            | sed -n 's/.*"id":\([0-9]\+\).*/\1/p' | head -1)
    [ -n "$build" ] || return 1
    product=$(wget -qO- "https://ci.guix.gnu.org/build/$build/details" \
              | sed -n 's|.*href="\(/download/[0-9]\+\)".*|\1|p' | head -1)
    [ -n "$product" ] || return 1
    echo "https://ci.guix.gnu.org$product"
}
ROOT_GUIX=/var/guix/profiles/per-user/root/current-guix
PINNED_COMMIT=$(sed -n 's/.*(commit "\([0-9a-f]\{40\}\)").*/\1/p' etc/ci-guix-channels.scm)

say() { printf '\033[1;34m[ci-setup-guix]\033[0m %s\n' "$*"; }

ensure_system_deps() {
    # netbase provides /etc/services, without which guix's substituter
    # fails name resolution ("Servname not supported for ai_socktype")
    # and silently builds the world from bootstrap instead.
    if ! { command -v wget && command -v xz && command -v pgrep && \
           command -v git && [ -e /etc/services ]; } >/dev/null 2>&1; then
        say "installing system deps (wget xz netbase procps git)"
        apt-get update -qq
        apt-get install -y -qq wget xz-utils netbase procps ca-certificates git
    fi
}

install_binary() {
    say "installing Guix nightly binary tarball"
    if ! wget -q -O /tmp/guix-binary.tar.xz "$GUIX_TARBALL_URL"; then
        say "pinned tarball URL gone; resolving latest nightly"
        GUIX_TARBALL_URL=$(latest_tarball_url)
        say "resolved: $GUIX_TARBALL_URL"
        wget -q -O /tmp/guix-binary.tar.xz "$GUIX_TARBALL_URL"
    fi
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
    # setsid detaches the daemon from the CI step's process group so it
    # survives into later workflow steps.
    rm -f /var/guix/daemon-socket/socket
    setsid "$ROOT_GUIX/bin/guix-daemon" --build-users-group=guixbuild \
           --disable-chroot >/var/log/guix-daemon.log 2>&1 &
    sleep 1
    pgrep -f guix-daemon >/dev/null || \
        { say "daemon failed to start"; cat /var/log/guix-daemon.log; exit 1; }
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
    # Skip the expensive pull entirely when the installed (nightly) guix
    # is recent enough to load the channel's modules — the channel only
    # needs current-master APIs, not one exact commit, for CI builds.
    if guix repl -L . >/dev/null 2>&1 <<'EOF'
(use-modules (etc ci-packages) (btc packages rust-crates))
EOF
    then
        say "installed guix loads the channel; skipping guix pull"
        return
    fi
    say "guix pull to pinned commit ${PINNED_COMMIT} (one-time; cached afterwards)"
    # libgit2's TLS transport reliably fails (EAGAIN) on the large guix
    # clone in CI containers; clone with system git instead and pull from
    # the local mirror.  A bare clone carries all branches, including the
    # keyring branch needed for channel authentication.
    mirror=/tmp/guix-channel-mirror.git
    if [ ! -d "$mirror" ]; then
        n=0
        until git clone --quiet --bare \
                  https://codeberg.org/guix/guix.git "$mirror"; do
            rm -rf "$mirror"
            n=$((n + 1))
            [ "$n" -ge 3 ] && { say "channel clone failed after $n attempts"; exit 1; }
            say "clone attempt $n failed; retrying in 30s"
            sleep 30
        done
    fi
    sed "s|\"https://[^\"]*guix.git\"|\"file://$mirror\"|" \
        etc/ci-guix-channels.scm > /tmp/ci-channels.scm
    n=0
    until guix pull -C /tmp/ci-channels.scm; do
        n=$((n + 1))
        [ "$n" -ge 3 ] && { say "guix pull failed after $n attempts"; exit 1; }
        say "guix pull attempt $n failed; retrying in 30s"
        sleep 30
    done
    ln -sf /root/.config/guix/current/bin/guix /usr/local/bin/guix
    hash -r 2>/dev/null || true
}

case "${1:-ensure}" in
    ensure)
        ensure_system_deps
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
