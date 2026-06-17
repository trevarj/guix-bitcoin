# Reproducibility & bootstrapping

This channel serves no binary substitutes — every package is built from source
on your machine. This guide shows how to build and verify a node, and how to
bootstrap its whole toolchain from Guix's 357-byte seed — matching, and going
beyond, Bitcoin Core's reproducible-build philosophy.

## Vs. Bitcoin Core

Bitcoin Core's release builds (`contrib/guix/` + `bitcoin-core/guix.sigs`) use
Guix to produce reproducible binaries that multiple builders attest to, pinning
a Guix revision and trusting Guix's toolchain. Here you are your own builder: you
compile from source locally and verify the build is bit-for-bit reproducible.

## What "no substitutes" covers

| Layer | Built locally from source? |
|-------|----------------------------|
| Bitcoin apps (bitcoin-core, electrs, lnd, …) | Always — the channel ships no app binaries |
| Dependencies (boost, gcc, glibc, …) | Only with `--no-substitutes`; otherwise from `ci.guix.gnu.org` |
| Bootstrap seed | Downloaded as source inputs; rebuilt from `hex0` only on a full bootstrap (below) |

## Build from source

```sh
guix build -L . bitcoin-core
```

Compiles bitcoin-core locally; dependencies come from `ci.guix.gnu.org`. Minutes.

## Build everything from source

```sh
guix build -L . --no-substitutes bitcoin-core
```

Builds the whole dependency graph locally — no server trusted for any package
output. Hours, and tens of GB of store on first run.

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

On `x86_64-linux`/`i686-linux`, `bitcoin-core`'s C toolchain roots in a 357-byte
`hex0` seed, with no prebuilt compiler trusted in between (`guile-bootstrap`,
~25 MB, drives the builds). This goes beyond Bitcoin Core's own reproducible
builds, which trust Guix's prebuilt toolchain.

Prove the dependency graph reaches the seed:

```sh
guix graph -L . -t bag bitcoin-core | grep stage0-posix
```

`stage0-posix` carries `hex0`; the downloaded binary toolchain seeds
(`%bootstrap-gcc`, `%bootstrap-glibc`) do not appear in the graph. The
`--no-substitutes` build above compiles every rung below from source.

### The chain

Each rung is compiled by the previous one (versions from the current graph):

| Stage | Packages |
|-------|----------|
| Seed | `stage0-posix@1.6.0` — 357-byte `hex0` → hex1/hex2/M0/M2-Planet + mescc-tools |
| Scheme shell/tools | `bootar`, `gash-boot`, `gash-utils-boot` — Guile `tar`/shell, so no trusted `bash`/coreutils |
| Scheme C compiler | `mes-boot@0.25.1` — GNU Mes + MesCC |
| Real C compiler | `tcc-boot0` → `tcc-boot@0.9.27` — TinyCC, built by MesCC |
| First GCC + glibc | `binutils-mesboot0@2.20.1a` → `gcc-core-mesboot0@2.95.3` → `glibc-mesboot0@2.2.5` → `gcc-mesboot0@2.95.3` |
| Iterate toolchain | `gcc-mesboot1@4.6.4` → `binutils-mesboot@2.20.1a` → `glibc-mesboot@2.16.0` → `gcc-mesboot@4.9.4` |
| GNU userland | `bash-mesboot`, `coreutils-mesboot@9.1`, `sed-mesboot`, `grep-mesboot`, `gawk-mesboot`, `tar-mesboot`, `xz-mesboot`, `gzip-mesboot`, `make-mesboot` |
| Final toolchain | Guix's modern gcc / glibc / binutils / guile |
| Node deps | cmake, boost, libevent, sqlite, … |
| **Node** | **bitcoin-core** |

### Building it

```sh
# Everything from the seed up. Hours to a day-plus; x86 only.
guix build -L . --no-substitutes bitcoin-core

# Inspect any single rung:
guix build -e '(@@ (gnu packages commencement) stage0-posix)'
guix build -e '(@@ (gnu packages commencement) mes-boot)'
guix build -e '(@@ (gnu packages commencement) gcc-mesboot)'
```

The early rungs (`hex0` → `gcc-mesboot`) are largely single-threaded — the slow
part. See `info "(guix) Full-Source Bootstrap"`.

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
| Prove chain reaches seed | `guix graph -t bag bitcoin-core \| grep stage0-posix` |
| Bootstrap seed tarballs | `guix build bootstrap-tarballs` |
