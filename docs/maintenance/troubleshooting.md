# Troubleshooting & gotchas

Hard-won lessons from packaging this channel. Grouped by where they bite.

## Guile / Guix scripting

- **`guix repl` output has a banner / REPL prompt mixed in.** A here-doc
  (`guix repl <<EOF`) starts an interactive REPL and prints the banner to
  *stdout*, which poisons any parsing. Use **script mode**: write the code to a
  file and `guix repl -L . -- FILE`; pass inputs via environment variables. See
  `etc/source-hash.sh` and `etc/ci-refresh-report.sh`.
- **`substitute*` doesn't match a line `grep` clearly matches.** Anchored
  patterns (`^CPATH=/usr/local/lib$`) can silently fail to substitute. Use the
  unanchored substring (`CPATH=/usr/local/lib`). This was the Core Lightning
  zlib-probe fix.
- **A CI shell script behaves differently when you test it locally.** zsh does
  not word-split unquoted `$var`; CI's `sh`/`bash` do. Test CI snippets with
  `sh -c '…'`, not the interactive zsh.

## Fixed-output (FOD) reproducibility

- **An npm-cache FOD hash differs between runs.** npm's `cacache` embeds
  timestamps and is not bit-reproducible. Vendor a normalized `node_modules`
  tree with flattened mtimes instead (`bitcoin/build/npm-vendor.scm`).
- **A compiled FOD hash differs between machines.** A cdylib built under CI's
  Guix differed from the maintainer's. Compiled artifacts are *not* reproducible
  across toolchains — make them a **regular package** (`cargo-build-system`,
  etc.), not an FOD. Reserve FODs for fetch-and-normalize (`go mod vendor`,
  `npm install`). This is why `mempool-rust-gbt` is a normal package.
- **Bumping a vendored package.** Set the hash to all-zeros, then
  `etc/harvest-fod-hash.sh <pkg> --fix <file>` (one placeholder at a time).

## Non-FHS build systems (e.g. Core Lightning)

A bespoke `./configure` + `Makefile` that assumes `/usr/local`:

- **`HAVE_ZLIB=0`, then `gossmap-compress.c` fails on implicit `gzopen`.**
  `configure` hardcodes `CPATH=/usr/local/lib` / `LIBRARY_PATH=/usr/local/lib`
  and probes with `-I$CPATH -L$LIBRARY_PATH` (empty on Guix). Patch both in
  `configure` to point at the dependency, **and** in the top `Makefile` (which
  reassigns and auto-exports them), and strip `-L$(CPATH)` from `LDLIBS` (a bare
  `-L` swallows the next flag).
- **Vendored submodule configure fails (`config.sub: not found`, "cannot
  execute").** Set `CONFIG_SHELL=$(which sh)` and route the sub-configures
  through it via `substitute*` on `external/Makefile`.
- **A script invoked directly fails with "Permission denied".** It lacks the
  exec bit in the tarball — `chmod` it in a phase (e.g.
  `devtools/blockreplace.py`).
- **`configure: error: cannot import "distutils"`.** distutils was removed in
  Python 3.12 — add `python-setuptools` to `native-inputs`.
- **In-tree submodules missing.** Use `(recursive? #t)` in the `git-reference`.

## Bitcoin Core / Knots functional tests

- **`interface_bitcoin_cli.py` / `rpc_bind.py --ipv6` fail.** Build containers
  and CI lack IPv6 (`::1`). Exclude them in the `check-functional` phase. Core
  takes one `--exclude=` per test; **Knots** takes a single comma-separated
  `--exclude=` and matches exact variant names.

## Services at runtime

- **A cookie-auth daemon (electrs, …) crash-loops on
  `failed to open cookie file: Permission denied`.** bitcoind forces
  `umask 077`, so its per-network directory is `0700` and the group-readable
  `.cookie` is unreachable. The `bitcoind-cookie-access` one-shot in
  `bitcoin/services/bitcoin.scm` chmods the directory `0750` once the cookie
  appears; dependents must list it in `requirement`.
- **`service 'bitcoind' requires 'networking', which is not provided`.** Add
  `dhcpcd-service-type` (or another networking provider) to the OS — the example
  and the VM tests do.
- **electrs never opens its port on regtest.** It waits out IBD, which a
  zero-block regtest chain never leaves. Mine a block first (see `%test-electrs`).

## CI containers (`etc/ci-setup-guix.sh`)

- **`guix build: …setPersonality: Operation not permitted`.** Docker's default
  seccomp blocks `personality(2)`. Run the container with
  `--security-opt seccomp=unconfined`.
- **Substituter fails name resolution / the world builds from bootstrap.**
  Missing `/etc/services` — `apt-get install netbase`.
- **The daemon isn't alive in a later step.** Start `guix-daemon` with `setsid`
  and run setup + build in the **same** workflow step.
- **`guix pull` clone fails with TLS `EAGAIN`.** libgit2's transport chokes on
  the large guix clone in containers. Clone with system `git` and pull from a
  local mirror; use the Codeberg mirror URL.
- **`guix pull` from the 1.4.0 tarball crashes (`compute-guix-derivation`).**
  The release tarball is too old to pull to current master — bootstrap from a
  recent nightly binary tarball.
- **`guix lint` complains about bogus package names.** The here-doc REPL banner
  leaked into the argument list — use script mode (see above).

## Forge / remotes

- **Codeberg shared CI runners can't build the heavy sets** (4 CPU / 8 GB /
  short timeout). Use GitHub's free runners or register a self-hosted Forgejo
  runner.
- **A push to Codeberg fails with an SSH error.** Their SSH endpoint flakes
  intermittently; just retry the push.
