# Contributing

Maintainers: task-focused runbooks live in
[`docs/maintenance/`](docs/maintenance/README.md) (bumping packages, adding
packages/services, building & testing, keys & releasing, troubleshooting).

## Commit policy
- Every commit MUST be GPG-signed by a key listed in `.guix-authorizations`.
- One logical change per commit, GNU ChangeLog-style messages
  (see existing history).

## Merging a pull request (maintainer)
The channel requires every commit to be signed by an authorized key, and CI
cannot sign as the maintainer — so a contributor's commits arrive unsigned.
Do **not** `git merge` them directly (the `post-merge` / `pre-push`
`guix git authenticate` hooks will reject the unsigned commits). Instead
replay them onto master, which signs each commit with your key while keeping
the contributor as the commit Author:

```sh
etc/merge-pr.sh <PR-number>          # GitHub PR, from the 'github' remote
etc/merge-pr.sh origin pull/7/head   # or any remote + ref
```

The result: each commit is `Author: <contributor>`, `Commit: <you>`, signed
by your key and accepted by `guix git authenticate`. Review with `git show`,
then push to both remotes. (Set it up once: `git config commit.gpgsign true`
and `git config user.signingkey <your-key>`.)

## Version bumps

The full procedure (by source type, including upstream-signature verification
for bitcoin-core/knots and the FOD-hash workflow) is in
[`docs/maintenance/bumping-packages.md`](docs/maintenance/bumping-packages.md).
In short: edit `version`, recompute the hash with `etc/source-hash.sh`,
`guix build`/`guix lint`, and note the verification in the commit message.

Package builds run in CI automatically (`build-set.yml` builds the set matching
each changed file); the VM system tests are not run in CI, so run those locally
for service-affecting changes — see
[`docs/maintenance/building-and-testing.md`](docs/maintenance/building-and-testing.md).

## Tier policy
Security-critical packages (libraries, nodes) are full-purity: no vendored
dependency archives. Vendored tiers (rust crates, explorers) pin dependency
snapshots by hash via fixed-output derivations (`bitcoin/build/`).
