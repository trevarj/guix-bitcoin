# Adding a service

Service types live in `bitcoin/services/`. The template to copy is
`bitcoin/services/bitcoin.scm` (and the existing `indexers.scm` /
`lightning.scm`). The conventions below keep services consistent and make
cookie-based RPC auth work.

## Conventions

- **Config record**: `define-configuration/no-serialization` with typed,
  documented fields; destructure with `match-record`.
- **Config file**: generate it with `plain-file`; never put secrets in the store
  (use bitcoind's RPC cookie, referenced by path).
- **Dedicated user in the `bitcoin` group**: an `account-service-type` extension
  adds a system `user-account` whose group is `bitcoin` and whose shell is
  `nologin`. Group membership is what lets the daemon read bitcoind's
  group-readable `.cookie`.
- **State directory**: an `activation-service-type` extension does
  `mkdir-p`, `chown` to the service user, and `chmod #o750` on `/var/lib/<name>`.
- **Shepherd service**:
  - `provision '(<name>)`.
  - `requirement '(bitcoind bitcoind-cookie-access user-processes networking)`
    for anything that reads the node's cookie. `bitcoind-cookie-access` is a
    one-shot in `bitcoin/services/bitcoin.scm` that opens bitcoind's per-network
    directory to the `bitcoin` group (bitcoind forces `umask 077`, so without it
    the cookie is unreadable — see [troubleshooting.md](troubleshooting.md)).
  - `make-forkexec-constructor … #:user "<name>" #:group "bitcoin"
    #:log-file "/var/log/<name>.log"`.
  - `stop #~(make-kill-destructor SIGTERM #:grace-period 60)` (or 120 for the
    node, which flushes state).
- **Network awareness**: derive per-network paths/options with a `match` on the
  `network` symbol (`mainnet testnet signet regtest`), as the node service does
  with `network-data-directory`.

## Export and wire up

`#:export` the configuration constructor, predicate, and the `*-service-type`.
Add the new module to the loads in `tests/bitcoin.scm` if you write a test there.

## Add a VM system test

Extend `tests/bitcoin.scm` with a `system-test` (model on `%test-electrs`):

- Build a `simple-operating-system` with `dhcpcd-service-type` (provides
  `networking`), the node service, and your service.
- In the marionette: `wait-for-service` (wrap in a retry loop — shepherd may
  start late), then assert the daemon actually works.
- **Mine a block first** if the daemon waits out IBD: a fresh regtest chain has
  zero blocks and never leaves IBD, so generate one before expecting the service
  to come up (see the "mine a block to clear IBD" step in `%test-electrs`).

Export the new `%test-…` and run it:

```sh
guix build -L . -e '(@ (tests bitcoin) %test-<name>)'
```

## Verify

```sh
guix repl -L . -- /dev/stdin <<'EOF'
(use-modules (bitcoin services <module>))
(format #t "~a~%" <name>-service-type)
EOF
guix system build -L . examples/node-os.scm   # if you add it to the example
```
