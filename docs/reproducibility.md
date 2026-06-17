# Reproducibility & bootstrapping

This channel serves no binary substitutes — every package is built from source
on your machine. This guide shows how to build, verify, and optionally bootstrap
a node from a minimal trusted seed.

## Vs. Bitcoin Core

Bitcoin Core's release builds (`contrib/guix/` + `bitcoin-core/guix.sigs`) use
Guix to produce reproducible binaries that multiple builders attest to, pinning
a Guix revision and trusting Guix's toolchain. Here you are your own builder: you
compile from source locally, verify the build is bit-for-bit reproducible, and
can push the trust root down to Guix's 357-byte full-source bootstrap seed.

## What "no substitutes" covers

| Layer | Built locally from source? |
|-------|----------------------------|
| Bitcoin apps (bitcoin-core, electrs, lnd, …) | Always — the channel ships no app binaries |
| Dependencies (boost, gcc, glibc, …) | Only with `--no-substitutes`; otherwise from `ci.guix.gnu.org` |
| Bootstrap seed | Downloaded as source inputs unless you rebuild it |

## Build from source

```sh
guix build -L . bitcoin-core
```

Compiles bitcoin-core locally; dependencies come from `ci.guix.gnu.org`. Minutes.

## Build everything from source

```sh
guix build -L . --no-substitutes bitcoin-core
```

Builds the whole dependency graph above the bootstrap seed locally — no server
trusted for any package output. Hours, and tens of GB of store on first run.

## Verify reproducibility

```sh
# Build twice; fail if the outputs differ.
guix build -L . --rounds=2 --keep-failed bitcoin-core

# Rebuild a store item and compare against the existing copy.
guix build -L . --check --keep-failed bitcoin-core

# Compare your build against public servers.
guix challenge bitcoin-core \
  --substitute-urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org" \
  --diff=diffoscope
```

`--rounds`/`--check` catch nondeterminism in your own build; `guix challenge`
compares hashes with other builders.

The channel pins bitcoin-core 31.0 while Guix proper is at 30.0, so
`guix challenge` usually reports "local hash only" for the package itself — it is
most useful on shared dependencies. Use `--rounds`/`--check` for the channel's
own packages.

If a `--rounds` build differs, inspect the divergence:

```sh
guix shell diffoscope -- diffoscope <out-a> <out-b>
```

Wrapper script: [`examples/verify-bitcoin-core.sh`](../examples/verify-bitcoin-core.sh).

## Full-source bootstrap

Guix roots its entire package graph in a 357-byte `hex0` seed plus a ~25 MB
`guile-bootstrap` driver, which bootstraps GNU Mes → tinycc → gcc → everything
else. `x86_64-linux` and `i686-linux` only.

The seed tarballs are downloaded by default, even with `--no-substitutes`. To
build them from the seed yourself:

```sh
guix build bootstrap-tarballs
```

Many hours to a day-plus, largely single-threaded. See `info "(guix) Bootstrapping"`.

## Expected reproducibility

Verify per release with `--rounds=2`:

- C++/CMake (bitcoin-core, bitcoin-knots): reproducible — built with the GUI off
  (no Qt) and `BITCOIN_GENBUILD_NO_GIT=1`.
- Go (btcd, lnd): reproducible.
- Rust (electrs, bdk-cli): reproducible.

## Attestation

Reproducibility proves "this source yields this binary"; attestation adds "and
others got the same binary." Compare your hashes against other builders'. The
`reproduce` workflow builds a package with `--rounds=2` and publishes its
`SHA256SUMS`:

```sh
gh workflow run reproduce.yml -f package=bitcoin-core
```

## Quick reference

| Goal | Command |
|------|---------|
| Build from source | `guix build -L . bitcoin-core` |
| Build everything from source | `guix build -L . --no-substitutes bitcoin-core` |
| Verify (self) | `guix build -L . --rounds=2 --keep-failed bitcoin-core` |
| Verify (vs others) | `guix challenge bitcoin-core --diff=diffoscope` |
| Reproduce a toolset | `guix shell --pure --no-substitutes -m examples/reproduce-manifest.scm` |
| Bootstrap seed | `guix build bootstrap-tarballs` |
