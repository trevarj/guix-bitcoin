# Reproducibility & bootstrapping

This channel serves **no binary substitutes**: every package is built from
source on your machine (see the README's "Building / substitutes"). This guide
explains exactly what that buys you, how to *verify* it, and how far down you
can push the trust root — in the spirit of Bitcoin Core's reproducible builds,
using Guix's bootstrappability.

## How this compares to Bitcoin Core

Bitcoin Core's release process (`contrib/guix/` + the `bitcoin-core/guix.sigs`
repo) uses **Guix itself** to produce **reproducible** binaries that **multiple
independent builders attest to** with matching hashes. Crucially, Core *pins a
Guix revision* (`guix time-machine`) and trusts Guix's toolchain binaries — it
is reproducible-and-attested, **not** a full-source bootstrap.

With this channel you are effectively your own builder: you compile the node
from source locally. Guix then lets you go in two directions Core's process
does not give an end user out of the box:

- **Verify** your build is bit-for-bit reproducible (`guix build --check`,
  `--rounds`, `guix challenge`).
- **Bootstrap** the entire toolchain from a tiny auditable seed (Guix's
  full-source bootstrap — a 357-byte program), collapsing the trust root far
  below what Core's pinned-Guix approach assumes.

The one thing a single channel cannot give you alone is **multi-party
attestation** (many independent builders agreeing on a hash). See
[Multi-party attestation](#multi-party-attestation).

## Three trust layers (don't conflate them)

| Layer | What "no substitutes" changes | What it does not change |
|-------|-------------------------------|-------------------------|
| **Application** (bitcoin-core, electrs, lnd, …) | Built locally from source; you never run a binary this channel produced | — |
| **Dependencies** (boost, cmake, gcc, glibc, …) | This channel offers no substitutes of its own | A normal Guix install still pulls these from `ci.guix.gnu.org` unless you add `--no-substitutes` |
| **Bootstrap seed** | Unaffected | The seed tarballs are fetched as source inputs unless you explicitly rebuild them |

In short: the channel guarantees the *Bitcoin applications* are built from
source. Building the *dependency graph* and the *bootstrap seed* from source are
additional choices you make (levels b and d below).

## The trust ladder

From least to most paranoid. Each builds on the previous.

### (a) Build the application from source

```sh
guix build -L . bitcoin-core
```

Compiles bitcoin-core locally from audited source. Dependencies come from
`ci.guix.gnu.org` as substitutes. **Proves:** you never run an application
binary this channel built. **Cost:** minutes (deps downloaded).

### (b) Full local source build (no substitutes)

```sh
guix build -L . --no-substitutes bitcoin-core
```

Builds the *entire dependency graph above the bootstrap seed* locally — boost,
qt-less node, cmake, gcc, glibc, … **Proves:** no server is trusted for any
package output. **Cost:** hours and tens of GB of store on first run.

### (c) Verify reproducibility

```sh
# Your build is internally deterministic (no external reference needed):
guix build -L . --rounds=2 --keep-failed bitcoin-core

# An item already in your store rebuilds bit-for-bit identically:
guix build -L . --check --keep-failed bitcoin-core

# Compare your local build against the public Guix CI (best for shared deps):
guix challenge bitcoin-core \
  --substitute-urls="https://ci.guix.gnu.org https://bordeaux.guix.gnu.org" \
  --diff=diffoscope
```

`--rounds`/`--check` detect nondeterminism in *your* build; `guix challenge`
compares against other builders' hashes — the lightweight analogue of
`guix.sigs` multi-attestation. **Cost:** roughly one extra build each;
`challenge` is just a hash comparison.

> Caveat: `guix challenge` only has a public counterpart for store items the CI
> actually built. This channel pins **bitcoin-core 31.0** while Guix proper is
> at 30.0, so the channel's exact derivation usually reports "local hash only."
> `challenge` is most useful on the **shared dependency graph** (boost, gcc,
> glibc, …); use `--rounds`/`--check` for the channel's own packages.

A convenience wrapper is in [`examples/verify-bitcoin-core.sh`](../examples/verify-bitcoin-core.sh).

### (d) Full-source bootstrap (document-only)

Guix's **full-source bootstrap** roots its entire >22,000-package graph in a
**357-byte `hex0` seed** (plus a ~25 MB `guile-bootstrap` build driver and a set
of historical GNU intermediate packages), on `x86_64-linux`/`i686-linux` only
(milestone merged 2023). This is the maximal audit story: trust collapses to a
program small enough to read by hand.

By default the bootstrap *seed tarballs* are downloaded as source inputs even
with `--no-substitutes`. To exercise the seed-up path yourself:

```sh
# Rebuild the bootstrap tarballs (traditional + reduced binary seed):
guix build bootstrap-tarballs

# Or build up from the Mes/mescc C bootstrap explicitly:
guix build --no-substitutes \
  -e '(@@ (gnu packages commencement) gcc-core-mesboot0)'
```

**Proves:** the toolchain itself is built from an auditable seed, not trusted as
a binary. **Cost:** many hours to over a day of (largely single-threaded) CPU
and a large store; **x86_64/i686 only** (aarch64 not yet). Treat this as "the
trust root exists and is auditable," not a routine step.

See the Guix manual: `info "(guix) Bootstrapping"` and
`info "(guix) Invoking guix build"`.

## Is the node actually reproducible?

General Guix experience, verify per release with `--rounds=2`:

- **C++/CMake** (bitcoin-core, bitcoin-knots): generally reproducible. Guix
  neutralizes build-path, `SOURCE_DATE_EPOCH`, and locale; the package sets
  `BITCOIN_GENBUILD_NO_GIT=1`. The node builds with the GUI off, avoiding Qt.
- **Go** (btcd, lnd): usually deterministic; vendoring pins inputs.
- **Rust** (electrs, bdk-cli): usually deterministic.

If `--rounds=2` ever fails, keep the divergent output (`--keep-failed`) and
inspect with `guix shell diffoscope -- diffoscope <a> <b>`.

## Multi-party attestation

Reproducibility says *"this source yields this binary."* Attestation adds
*"and N independent parties got the same binary."* That is the strength of
`bitcoin-core/guix.sigs`, and it inherently needs more than one builder, so a
single channel cannot provide it alone.

What the channel can do toward it (scope / future work):

- Publish `SHA256SUMS` of the `nodes`-set package outputs per channel commit
  (a `guix.sigs`-style directory), so anyone who runs level (b)/(c) can compare
  their hashes to ours.
- A standing CI reproducibility job (`--rounds=2` on the `nodes` set) makes the
  channel a single-party attestor — a baseline others can check against.
- Independent builders publishing their own matching hashes is what turns this
  into real multi-party attestation.

## Quick reference

| Goal | Command |
|------|---------|
| Build app from source | `guix build -L . bitcoin-core` |
| Build everything from source | `guix build -L . --no-substitutes bitcoin-core` |
| Reproducible (self) | `guix build -L . --rounds=2 --keep-failed bitcoin-core` |
| Reproducible (vs others) | `guix challenge bitcoin-core --diff=diffoscope` |
| Reproduce a whole toolset | `guix shell --pure --no-substitutes -m examples/reproduce-manifest.scm` |
| Full-source bootstrap | `guix build bootstrap-tarballs` (x86, hours+) |
