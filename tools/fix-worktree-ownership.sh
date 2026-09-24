#!/usr/bin/env bash
#
# fix-worktree-ownership.sh -- make the worktree deployable again.
#
#   ./tools/fix-worktree-ownership.sh            show what is wrong
#   ./tools/fix-worktree-ownership.sh --apply    move it out and fix ownership
#
# THE FAILURE THIS CLEARS
#
#     fatal: cannot create directory at 'arms/_pin-cfg': Permission denied
#      ! [remote rejected] main -> main (push-to-checkout hook declined)
#
#   Most of this kit runs under sudo, so directories it wrote into the worktree
#   are owned by root: `sudo 02-make-arms.sh` created arms/, `sudo gvpn-bench.sh`
#   created bench-runs/. The deploy runs as you, and git cannot create a new
#   subdirectory inside a directory owned by root. git's message names the path
#   it tripped over and not the reason, which is why this script exists.
#
#   The fix is the restructure's own premise: none of that belongs in the
#   worktree. It moves into the state directory, where no deploy can touch it.
#
#   Safe to run twice. Nothing is deleted -- directories are moved, and the old
#   rendered arms are kept as arms-old until the new ones are validated.
#
set -euo pipefail

WORKTREE="${GVPN_WORKTREE:-$PWD}"
STATE="${GVPN_STATE:-$HOME/gvpn-state}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
case "${1:-}" in -h|--help) sed -n '2,27p' "$0"; exit 0 ;; esac

ME="$(id -un)"
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

cd "$WORKTREE"
[ -d .git ] || { echo "not a git worktree: $WORKTREE" >&2; exit 1; }

say "scanning $WORKTREE for paths $ME cannot write"
FOREIGN="$(find . -path ./.git -prune -o ! -user "$ME" -print 2>/dev/null || true)"
if [ -z "$FOREIGN" ]; then
  echo "    nothing foreign-owned -- this is not what is blocking the push."
  echo "    Check instead:"
  echo "      ls -l $STATE/run.lock        # a run in progress also blocks deploys"
  echo "      git -C . status --short      # a conflicting local change"
  exit 0
fi

printf '%s\n' "$FOREIGN" | head -10 | sed 's/^/    /'
N=$(printf '%s\n' "$FOREIGN" | wc -l)
[ "$N" -gt 10 ] && echo "    ... and $((N - 10)) more"
echo
echo "    owners: $(printf '%s\n' "$FOREIGN" | xargs -r stat -c '%U' 2>/dev/null | sort -u | tr '\n' ' ')"

if [ "$APPLY" = 0 ]; then
  cat <<EOF

Nothing changed. Re-run with --apply to move these into $STATE:

    $0 --apply

You will be asked for your sudo password -- the files are root-owned.
EOF
  exit 0
fi

# ------------------------------------------------------------------- apply --

say "creating $STATE"
mkdir -p "$STATE"/{runs,arms,secrets,identity-backup}
chmod 700 "$STATE/secrets" "$STATE/identity-backup"

if [ -d bench-runs ]; then
  say "moving bench-runs/ -> $STATE/runs/"
  # Move the RUNS, not the directory: $STATE/runs may already hold some.
  sudo find bench-runs -maxdepth 1 -mindepth 1 -exec mv -t "$STATE/runs/" {} + 2>/dev/null || true
  sudo rmdir bench-runs 2>/dev/null && echo "    bench-runs/ removed" \
    || echo "    bench-runs/ not empty -- left in place, inspect it"
fi

if [ -d arms ]; then
  # The incoming tree has its own arms/ (the templates), so the rendered
  # instances cannot stay under that name. Keep them: they are the only record
  # of what the previous runs actually used.
  DEST="$STATE/arms-old"
  [ -e "$DEST" ] && DEST="$STATE/arms-old-$(date -u +%Y%m%d%H%M%S)"
  say "moving arms/ -> $DEST  (rendered instances, kept for reference)"
  sudo mv arms "$DEST"
fi

for f in faucet-codes faucet-codes.used; do
  [ -f "$f" ] || continue
  say "moving $f -> $STATE/secrets/"
  sudo mv "$f" "$STATE/secrets/"
done

say "handing $STATE back to $ME"
sudo chown -R "$ME": "$STATE"
chmod 700 "$STATE/secrets" "$STATE/identity-backup" 2>/dev/null || true
chmod 600 "$STATE"/secrets/* 2>/dev/null || true

# Anything left is something this script did not anticipate -- a stray root-owned
# file from a hand-run command. Chown it rather than move it: it is inside the
# worktree, so it is either tracked (the deploy will replace it) or junk.
LEFT="$(find . -path ./.git -prune -o ! -user "$ME" -print 2>/dev/null || true)"
if [ -n "$LEFT" ]; then
  say "remaining foreign-owned paths -- taking ownership"
  printf '%s\n' "$LEFT" | sed 's/^/    /'
  printf '%s\n' "$LEFT" | sudo xargs -r chown -R "$ME":
fi

say "verifying"
LEFT="$(find . -path ./.git -prune -o ! -user "$ME" -print 2>/dev/null || true)"
if [ -n "$LEFT" ]; then
  echo "STILL FOREIGN-OWNED:" >&2
  printf '%s\n' "$LEFT" | sed 's/^/    /' >&2
  exit 1
fi
echo "    worktree is entirely owned by $ME"

if [ -e "$STATE/run.lock" ]; then
  echo
  echo "    NOTE: $STATE/run.lock exists -- a run is in progress, or it is stale"
  echo "    from a crashed one. Deploys stay blocked until it is gone."
fi

cat <<EOF

Done. Now push again from your laptop:

    make push          # or: git push origin main && git push vm main

Your old rendered arms are at $STATE/arms-old -- delete them once
'make arms' has produced new ones and 'use-arm.sh pin-planner --count' reads 1.
EOF
