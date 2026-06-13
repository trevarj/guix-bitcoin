# Contributing

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

## Version bump checklist
1. Check upstream release announcement and changelog.
2. Download the release tarball; verify the upstream signature:
   - bitcoin-core: verify `SHA256SUMS.asc` against builder keys from
     https://github.com/bitcoin-core/guix.sigs (`builder-keys/`), then
     compare `sha256sum` of the tarball with `SHA256SUMS`.
   - bitcoin-knots: same scheme via
     https://github.com/bitcoinknots/guix.sigs (branch `knots`).
   - libsecp256k1: verify the signed git tag.
3. Update `version` and `sha256` in the package definition.
4. `guix build -L . <package>` and `guix lint -L . <package>`.
5. For service-affecting changes, run the system tests locally — they are
   not run in CI:
   `guix build -L . -e '(@ (tests bitcoin) %test-bitcoin-node)'`.
   Package builds, on the other hand, ARE run in CI: `build-set.yml` maps
   each changed file to its set (`etc/ci-changed-sets.sh`) and builds those
   sets automatically on push, so touching `bitcoin/packages/nodes.scm`
   builds the `nodes` set. You can also trigger a set manually, e.g.
   `fj actions dispatch build-set.yml -f package_set=<set>` (Forgejo) or
   `gh workflow run build-set.yml -f package_set=<set>` (GitHub).
6. Note the verification performed in the commit message.

## Tier policy
Security-critical packages (libraries, nodes) are full-purity: no vendored
dependency archives. Vendored tiers (rust crates, explorers — later phases)
pin dependency snapshots by hash via helper scripts in `etc/`.
