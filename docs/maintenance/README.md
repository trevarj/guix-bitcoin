# Maintaining guix-bitcoin

Task-focused runbooks for keeping the channel current and healthy. Each is
self-contained; start from the table below.

| Task | Runbook |
|------|---------|
| Bump a package to a new upstream version | [bumping-packages.md](bumping-packages.md) |
| Triage the monthly "Package updates" issue | [bumping-packages.md](bumping-packages.md#triaging-the-monthly-update-issue) |
| Add a new package to the channel | [adding-a-package.md](adding-a-package.md) |
| Add a new Guix System service | [adding-a-service.md](adding-a-service.md) |
| Build / test locally and in CI | [building-and-testing.md](building-and-testing.md) |
| Signing, authorizations, releasing, merging PRs | [keys-and-releasing.md](keys-and-releasing.md) |
| Recover from a build/CI failure (gotchas) | [troubleshooting.md](troubleshooting.md) |

## Helper scripts (`etc/`)

| Script | Purpose |
|--------|---------|
| `source-hash.sh <pkg>` | Recompute a package's source `sha256` after editing its `version`. |
| `harvest-fod-hash.sh <pkg> [--fix FILE]` | Build a vendored package and read/splice its real fixed-output hash. |
| `ci-build.sh <set>` | Build a named package set (`libs nodes wallets indexers lightning rust explorers all lint`). |
| `ci-changed-sets.sh` | Map changed files to the sets CI should build. |
| `ci-refresh-report.sh` | The monthly update report (run by `refresh.yml`). |
| `ci-setup-guix.sh` | Install/restore Guix inside a CI container. |
| `merge-pr.sh <N>` | Integrate a contributor PR, signed by the maintainer, crediting the author. |

## Ground facts

- Modules live under `(bitcoin packages ...)` / `(bitcoin services ...)`; sources
  in `bitcoin/`. Always load the channel with `guix … -L .` from the repo root.
- Canonical authenticated origin: `origin` → Codeberg. CI mirror: `github`.
  Push to **both**.
- Every commit must be GPG-signed by a key in `.guix-authorizations`; the
  `pre-push`/`post-merge` hooks run `guix git authenticate`.
- No substitutes — everything builds from source.
