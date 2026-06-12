# Contributing

## Commit policy
- Every commit MUST be GPG-signed by a key listed in `.guix-authorizations`.
- One logical change per commit, GNU ChangeLog-style messages
  (see existing history).

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
5. For service-affecting changes, run the system tests:
   `guix build -L . -e '(@ (tests bitcoin) %test-bitcoin-node)'`.
6. Note the verification performed in the commit message.

## Tier policy
Security-critical packages (libraries, nodes) are full-purity: no vendored
dependency archives. Vendored tiers (rust crates, explorers — later phases)
pin dependency snapshots by hash via helper scripts in `etc/`.
