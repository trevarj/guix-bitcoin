# Adding a package

## 1. Write the package

Put it in the module that matches its domain, under `bitcoin/packages/`:

| Module | Holds |
|--------|-------|
| `libraries.scm` | crypto/JSON libraries |
| `nodes.scm` | full-node implementations |
| `wallets.scm` | wallets |
| `indexers.scm` | Electrum-protocol servers |
| `lightning.scm` | Lightning daemons |
| `rust-bitcoin.scm` | rust-bitcoin family (crates via `lookup-cargo-inputs`) |
| `explorers.scm` | block explorers |

Follow the existing definitions for style: the copyright header, a clear
`synopsis`/`description` (Guix conventions — no trailing period on synopsis),
and the right build system. For Rust apps, add the dependency rows to
`bitcoin/packages/rust-crates.scm` and pull them with
`(cargo-build-system … #:cargo-inputs (lookup-cargo-inputs 'name))`. For vendored
Go/npm sources, reuse `bitcoin/build/go-vendor.scm` / `bitcoin/build/npm-vendor.scm`
and harvest the FOD hash (see [bumping-packages.md](bumping-packages.md#vendored-fixed-output-fod-packages)).

Recompute the source hash with `./etc/source-hash.sh <package>` once the package
is defined.

## 2. Wire it into the build sets

In `etc/ci-packages.scm`:

- Add the variable to the set list it belongs to (e.g. `%indexer-packages`).
- It is included in `%all-packages` automatically via the `append` — no separate
  edit unless you add a whole new set.

If you add a **new set**, also add a `case` arm in `etc/ci-build.sh` and update
its usage strings.

## 3. Wire it into CI change-detection

In `etc/ci-changed-sets.sh`, add a `case` arm mapping the new file to its set so
a push that touches it builds the right set:

```sh
bitcoin/packages/<module>.scm) add <set> ;;
```

(Files shared across sets — like a crate table or build helper — map to `all`.)

## 4. Update the docs

In `README.md`, add the package to the Build-status table's set row and to the
package-versions table.

## 5. Release tracking (custom download URLs only)

If the source is git-tag or crates.io, `guix refresh` tracks it for the monthly
report automatically — nothing to do. If it downloads from a custom URL that
`guix refresh` can't follow, add a `release_repo` arm in
`etc/ci-refresh-report.sh` pointing at the GitHub repo whose Releases page tracks
it (as done for `bitcoin/bitcoin`, `bitcoinknots/bitcoin`, `mempool/mempool`).

## 6. Verify

```sh
guix repl -L . -- /dev/stdin <<'EOF'
(use-modules (etc ci-packages) (guix packages))
(format #t "~a packages~%" (length %all-packages))
EOF
guix lint -L . <package>
guix build -L . <package>
```
