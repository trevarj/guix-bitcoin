# Bumping packages

The procedure depends on how the package fetches its source. Find the package's
type below. In every case: edit the `.scm`, recompute the hash, build, commit a
signed change describing the verification you did.

General loop:

```sh
$EDITOR bitcoin/packages/<module>.scm      # change version (and hash placeholder)
./etc/ci-build.sh <set>                     # or: guix build -L . <package>
guix lint -L . <package>
git commit -S -m "packages: update <package> to <version>"
```

`<set>` is the build-set the package belongs to — see `etc/ci-packages.scm`.

## git-tag and url-fetch packages

Most packages: `libsecp256k1`, `fulcrum`, `electrs`, `electrum`, `hwi`,
`core-lightning`, the `lnd` source, `bitcoin-core`, `bitcoin-knots`.

1. Edit `version` in the package definition.
2. Recompute the `sha256` — let the helper fetch and hash the new source:

   ```sh
   ./etc/source-hash.sh <package>     # prints the base32 hash; works for both
                                       # git-fetch (clones the tag) and url-fetch
   ```

   Paste the printed hash into the package's `(base32 "…")`.
3. `guix build -L . <package>` and `guix lint -L . <package>`.

### bitcoin-core / bitcoin-knots — verify the upstream signature

Before trusting the tarball, verify upstream's signed checksums:

- **bitcoin-core**: fetch `SHA256SUMS` and `SHA256SUMS.asc` from the release
  directory, verify the `.asc` against builder keys in
  <https://github.com/bitcoin-core/guix.sigs> (`builder-keys/`), then confirm the
  tarball's `sha256sum` matches the entry in `SHA256SUMS`.
- **bitcoin-knots**: same scheme via <https://github.com/bitcoinknots/guix.sigs>
  (branch `knots`).

Note the verification in the commit message.

## Rust crates (rust-bitcoin family, electrs dependencies)

Crate dependency closures are pinned in `bitcoin/packages/rust-crates.scm` (a
mostly machine-generated table) and consumed via `(lookup-cargo-inputs 'name)`.

To bump a library crate (e.g. `rust-bitcoin`) or refresh a dependency closure:

1. Regenerate that app/library's rows per the procedure documented in the header
   of `bitcoin/packages/rust-crates.scm` — generate a `Cargo.lock` and run
   `guix import crate --lockfile=<lock> <name>`.
2. Merge the new `crate-source` defs (dedupe by crate+version, keep alphabetical)
   and replace the relevant `define-cargo-inputs` row.
3. For pregenerated-file warnings (`winapi`, `windows_*`, `wit-bindgen`) copy the
   upstream `#:snippet '(delete-file …)` for that crate from
   `~/Workspace/guix/gnu/packages/rust-crates.scm`.
4. For the library package itself (`bitcoin/packages/rust-bitcoin.scm`), bump
   `version` and recompute the crate tarball hash:

   ```sh
   guix download "https://crates.io/api/v1/crates/<crate>/<version>/download" | tail -1
   ```

`rust-crates.scm` changing maps to the `all` CI set (it is shared by electrs,
the rust family, and mempool's rust-gbt).

## Vendored fixed-output (FOD) packages

`lnd` (Go modules) and the mempool `node_modules` trees pin a content hash that
can't be known until the FOD is built once. Helpers: `etc/harvest-fod-hash.sh`.

1. Bump the version (and the plain `git-fetch` source hash with
   `etc/source-hash.sh` where applicable).
2. Reset the vendored hash to the all-zeros placeholder:
   `"0000000000000000000000000000000000000000000000000000"`
   - `lnd`: the `vendored-hash` binding in `bitcoin/packages/lightning.scm`.
   - mempool: the `#:hash` of `%backend-node-modules` / `%frontend-node-modules`
     in `bitcoin/packages/explorers.scm`.
3. Harvest and splice the real hash:

   ```sh
   ./etc/harvest-fod-hash.sh lnd --fix bitcoin/packages/lightning.scm
   # mempool: run twice, once per cache (each has its own placeholder)
   ./etc/harvest-fod-hash.sh mempool-backend --fix bitcoin/packages/explorers.scm
   ```

   `--fix` only works when the file has exactly one all-zeros placeholder, so
   reset and harvest one hash at a time.
4. Build the package for real to confirm it now succeeds.

## commit-pinned packages

`libsecp256k1-zkp` tracks a vetted commit (upstream publishes no releases).

1. In `bitcoin/packages/libraries.scm`, update `commit` and **increment**
   `revision` (monotonic).
2. Recompute the hash: `./etc/source-hash.sh libsecp256k1-zkp`.

## Triaging the monthly update issue

The `refresh.yml` job opens a "Package updates — YYYY-MM" issue
(`etc/ci-refresh-report.sh`). Read the markers:

- **⬆️** — a newer upstream release exists. Bump it (sections above).
- **✅** — current; nothing to do.
- **🔍** — no automatic updater. Only `libsecp256k1-zkp` should appear here
  (commit-pinned). The node and explorer packages (custom download URLs) are
  release-checked against GitHub, so they show ⬆️/✅ like the rest; if you add a
  new custom-URL package, give it a `release_repo` entry in
  `etc/ci-refresh-report.sh`.

After bumping, push to both remotes; CI rebuilds the affected sets automatically.
