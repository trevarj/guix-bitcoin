# Building and testing

All commands run from the repo root and load the channel with `-L .`.

## Build a package or a set

```sh
guix build -L . bitcoin-core              # one package
./etc/ci-build.sh nodes                    # a named set
./etc/ci-build.sh all                      # everything
./etc/ci-build.sh lint                     # guix lint over every package
```

Sets: `libs nodes wallets indexers lightning rust explorers all lint`. The set
membership lives in `etc/ci-packages.scm`.

Heavy builds run in the foreground for a long time (bitcoin-core/knots run their
functional suites; lnd compiles its whole Go tree). Locally, just let them run;
in CI they have a generous timeout.

## VM system tests

The marionette tests boot a real VM (needs KVM: `/dev/kvm`):

```sh
guix build -L . -e '(@ (tests bitcoin) %test-bitcoin-node)'   # node + RPC + cookie perms
guix build -L . -e '(@ (tests bitcoin) %test-electrs)'        # node + electrs integration
```

They are **not** run in CI (no nested virt) — run them locally for
service-affecting changes.

## Example system

```sh
guix system build -L . examples/system-node.scm
```

A buildable, commented operating system (node plus optional indexer/Lightning/
explorer services). Confirms the service config-file generation, accounts, and
activation all evaluate.

## CI model

- **`check.yml`** — every push: `guix lint` + build the `libs` set, on a cached
  Guix install. Fast gate.
- **`build-set.yml`** — a `detect` job maps the push's changed files to sets
  (`etc/ci-changed-sets.sh`) and a matrix builds exactly those sets in parallel.
  Editing `bitcoin/packages/lightning.scm` builds only `lightning`. Dispatch a
  set by hand:

  ```sh
  gh workflow run build-set.yml -f package_set=nodes      # GitHub
  fj actions dispatch build-set.yml -f package_set=nodes  # Codeberg/Forgejo
  ```

- **`refresh.yml`** — monthly: runs `etc/ci-refresh-report.sh` and opens the
  "Package updates" issue. Trigger any time with `gh workflow run refresh.yml`.

### The Guix cache

CI caches the *Guix installation* (`/gnu`, `/var/guix`, the pull profile) keyed
on `etc/ci-guix-channels.scm` + `etc/ci-setup-guix.sh`, not built package
outputs — so packages build from source each run (by design). `check.yml`'s
`setup-guix` job populates the cache; other workflows restore it. Bump the pinned
commit in `etc/ci-guix-channels.scm` to move the whole fleet to a newer Guix.
