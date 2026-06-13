# Keys, authorizations, and releasing

The channel is authenticated: `guix git authenticate` walks history from the
introduction commit and requires every commit to be signed by a key listed in
`.guix-authorizations`. The `pre-push` and `post-merge` hooks run it
automatically, so a bad commit is caught before it leaves your machine.

## One-time signing setup

```sh
git config user.signingkey <your-key-id>
git config commit.gpgsign true
```

With these set, every commit (and the replays done by `etc/merge-pr.sh`) is
signed. Verify any commit with `git log --show-signature -1`.

## Pushing

Push to **both** remotes — Codeberg (`origin`, canonical/authenticated) and
GitHub (`github`, CI mirror):

```sh
git push origin master && git push github master
```

The `pre-push` hook re-authenticates the range. To check the whole history by
hand:

```sh
guix git authenticate 747b9cb83c0f88da46a14638165253b3b0d4b3bc \
  "A6C2 0D0C 2AD8 38F9 4907  0EA3 A52D 6879 4EBE D758"
```

(`747b9cb…` is the channel-introduction commit; the fingerprint is the founding
signer. These are also published in `README.md` for users' `channels.scm`.)

## Adding or rotating an authorized key

1. Add the new key's fingerprint to `.guix-authorizations`:

   ```scheme
   (("AAAA BBBB …  ⟨full fingerprint⟩"
     (name "alice")))
   ```

2. Export the public key onto the orphan `keyring` branch (where Guix looks for
   signer keys), then push it. The `keyring` branch has no authenticatable
   relationship to `master`, so its push must skip the hook:

   ```sh
   git checkout keyring
   gpg --armor --export <key-id> > alice.key
   git add alice.key && git commit -m "Add alice public key"
   git push --no-verify origin keyring && git push --no-verify github keyring
   git checkout master
   ```

3. The commit that adds the authorization must itself be signed by an
   already-authorized key.

## Merging a contributor PR

CI cannot sign as the maintainer, so a contributor's commits arrive unsigned and
a plain `git merge` would fail the hooks. Use the helper, which replays the PR's
commits onto master signed by your key while keeping the contributor as Author:

```sh
etc/merge-pr.sh <PR-number>          # GitHub PR via the 'github' remote
etc/merge-pr.sh origin pull/7/head   # or any remote + ref
```

Review with `git show`, then push to both remotes. Details and rationale in
`CONTRIBUTING.md` ("Merging a pull request").
