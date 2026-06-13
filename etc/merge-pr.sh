#!/bin/sh
# Integrate a contributor branch / pull request onto master so that every
# resulting commit is signed with the maintainer's GPG key -- required by
# `guix git authenticate` and this repo's pre-push / post-merge hooks --
# while keeping each commit's original Author, crediting the contributor.
#
# A plain `git merge` leaves the contributor's commits unsigned and fails
# authentication, so we replay (rebase) them onto master: rebase preserves
# each commit's Author and re-signs it under the committer (you).  --no-ff
# forces rebase to recreate the commits even when it could fast-forward,
# so the signature is actually applied.
#
# Usage:
#   etc/merge-pr.sh <N>              GitHub PR #N (from the 'github' remote)
#   etc/merge-pr.sh <remote> <ref>   any branch/ref (e.g. origin pull/7/head)
#
# After it succeeds and you have reviewed `git log`, push as usual; the
# pre-push hook re-authenticates the history:
#   git push origin master && git push github master
set -eu

die() { echo "merge-pr: $*" >&2; exit 1; }

# --- resolve the source ref ----------------------------------------------
if [ "$#" -eq 1 ]; then
    case "$1" in
        ''|*[!0-9]*) die "single argument must be a numeric GitHub PR number" ;;
    esac
    remote=github
    ref="pull/$1/head"
elif [ "$#" -eq 2 ]; then
    remote=$1
    ref=$2
else
    die "usage: merge-pr.sh <PR-number> | <remote> <ref>"
fi

# --- preconditions --------------------------------------------------------
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
[ "$(git symbolic-ref --short HEAD)" = master ] || die "not on master"
[ "$(git config commit.gpgsign 2>/dev/null || echo false)" = true ] \
    || die "commit.gpgsign is not true (run: git config commit.gpgsign true)"
git config user.signingkey >/dev/null 2>&1 || die "user.signingkey is not set"

echo "merge-pr: fetching $remote $ref"
git fetch --no-tags "$remote" "$ref"
src=$(git rev-parse FETCH_HEAD)

range="master..$src"
n=$(git rev-list --count "$range")
[ "$n" -gt 0 ] || die "no new commits in $ref relative to master"
if git rev-list --merges "$range" | grep -q .; then
    die "source contains merge commits; flatten/rebase it on master first"
fi
echo "merge-pr: replaying $n commit(s), signing with key $(git config user.signingkey)," \
     "authorship preserved"

# --- replay onto master, signed, author preserved -------------------------
# --no-ff: recreate every commit (and sign it) instead of fast-forwarding.
git branch -f _merge_pr "$src"
if ! git rebase --no-ff --gpg-sign --onto master master _merge_pr; then
    git rebase --abort 2>/dev/null || true
    git checkout -q master
    git branch -D _merge_pr 2>/dev/null || true
    die "rebase hit conflicts; rebase the PR onto master and retry"
fi
git checkout -q master
git merge --ff-only _merge_pr
git branch -D _merge_pr

# --- show the result ------------------------------------------------------
echo "merge-pr: integrated. New commits on master:"
git --no-pager log -"$n" --format='  %h  author:%an <%ae>  signer-key:%GK'
echo
echo "Review with 'git show', then push:"
echo "  git push origin master && git push github master"
