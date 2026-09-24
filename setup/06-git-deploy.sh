#!/usr/bin/env bash
#
# 06-git-deploy.sh -- turn the VM into a git push target, so you edit locally and
#                     `git push vm main` deploys.
#
# Run ONCE on the VM, as your normal user (not root):
#
#   ./06-git-deploy.sh              # in place: ~/gvpn-8408 IS the repo   [default]
#   ./06-git-deploy.sh --bare       # separate bare repo at ~/gvpn-8408.git
#
# It prints the commands to run on your Mac afterwards.
#
# IN-PLACE vs BARE
#
#   In place keeps everything under one directory: the repo is ~/gvpn-8408/.git
#   and there is no second path cluttering your home. Pushing into a repo whose
#   branch is checked out is refused by default, so this sets
#   receive.denyCurrentBranch=updateInstead, which is git's supported way to do
#   push-to-deploy.
#
#   Bare keeps the repo and the working copy apart, which some people prefer for
#   servers. Same result, one more directory.
#
# THE UNTRACKED-FILE WRINKLE, AND WHY THERE IS A push-to-checkout HOOK
#
#   `updateInstead` refuses a push that would overwrite an UNTRACKED file -- and
#   on a VM where the kit was first copied by hand, every file is untracked, so
#   the very first push fails with "would be overwritten by merge".
#
#   push-to-checkout is git's designed override for that. It makes the pushed
#   tree authoritative for the paths git actually tracks, while leaving
#   everything else on disk alone. That distinction is the whole safety story:
#
#     replaced   setup/, bench/, docs/, README.md, gvpn.conf   (tracked)
#     untouched  arms/, bench-runs/, faucet-codes, BUILD.txt   (gitignored)
#
#   So a deploy can never destroy a run in progress, the arm configs you
#   validated, your faucet codes, or the recorded build identity of the machine.
#
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

WORKTREE="${GVPN_WORKTREE:-$HOME/gvpn-8408}"
BRANCH="${GVPN_BRANCH:-main}"
MODE=inplace
BARE="${GVPN_BARE:-$HOME/gvpn-8408.git}"

usage() {
  cat <<EOF
06-git-deploy.sh -- make this VM a git push target

Usage: $0 [--bare] [--worktree DIR] [--branch NAME]

  --bare            separate bare repo at $BARE (default: repo lives in the worktree)
  --worktree DIR    deploy destination (default: $WORKTREE)
  --branch NAME     branch to deploy (default: $BRANCH)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bare)     MODE=bare; shift ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --branch)   BRANCH="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "installing git"; sudo apt-get install -y -qq git; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# The post-receive hook must not rely on its inherited working directory: during a
# push GIT_DIR is set, and `git rev-parse --show-toplevel` does not give the
# worktree. The path is baked in at install time instead.
write_post_receive() {  # write_post_receive HOOKS_DIR
  cat > "$1/post-receive" <<EOF
#!/usr/bin/env bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
cd "$WORKTREE" 2>/dev/null || exit 0
chmod +x setup/*.sh bench/*.sh bench/*.py 2>/dev/null || true
rc=0
for f in setup/*.sh bench/*.sh; do
  [ -f "\$f" ] || continue
  bash -n "\$f" 2>&1 || { echo "  !! SYNTAX ERROR in \$f"; rc=1; }
done
if ls bench/*.py >/dev/null 2>&1; then
  python3 -m py_compile bench/*.py 2>&1 && rm -rf bench/__pycache__ \\
    || { echo "  !! PYTHON SYNTAX ERROR in bench/"; rc=1; }
fi
[ \$rc -eq 0 ] && echo "  deployed $BRANCH -> $WORKTREE (syntax ok)" \\
               || echo "  deployed $BRANCH -> $WORKTREE  WITH ERRORS ABOVE"
EOF
  chmod +x "$1/post-receive"
}

if [ "$MODE" = inplace ]; then
  say "repo in place at $WORKTREE"
  mkdir -p "$WORKTREE"
  if [ -d "$WORKTREE/.git" ]; then
    echo "    already a git repo"
  else
    git init --quiet --initial-branch="$BRANCH" "$WORKTREE"
    echo "    initialised"
  fi
  GITDIR="$WORKTREE/.git"

  # Allow pushing to the branch that is checked out here.
  git -C "$WORKTREE" config receive.denyCurrentBranch updateInstead

  say "push-to-checkout hook"
  cat > "$GITDIR/hooks/push-to-checkout" <<HOOK
#!/bin/sh
set -e
# REFUSE TO DEPLOY DURING A RUN.
#
# push-to-checkout rewrites script files in place, and bash reads a script
# incrementally as it executes -- replacing gvpn-bench.sh under a running bench
# can make it jump to a wrong offset and execute garbage. Worse and quieter: a
# push can swap the analysis or an arm's planner settings halfway through a
# study, so the first twenty cycles and the last twenty measure different things
# and nothing in the output says so.
#
# Rejecting the push is the right failure. The alternative -- deploying anyway
# and hoping -- costs a 40-hour soak.
if [ -e "$GVPN_RUN_LOCK" ]; then
  echo "  !! REFUSING TO DEPLOY: a benchmark run is in progress" >&2
  echo "     \$(readlink "$GVPN_RUN_LOCK" 2>/dev/null)" >&2
  echo "     Wait for it to finish, or remove the lock if it is stale:" >&2
  echo "       rm $GVPN_RUN_LOCK" >&2
  exit 1
fi
# REFUSE TO DEPLOY INTO SOMEONE ELSE'S FILES.
#
# Most of this kit runs under sudo, so a directory it wrote into the worktree is
# owned by root -- \`sudo 02-make-arms.sh\` used to create arms/, \`sudo
# gvpn-bench.sh\` used to create bench-runs/. read-tree then cannot write inside
# them, and git's own message says only
#
#     fatal: cannot create directory at 'arms/_pin-cfg': Permission denied
#
# which names the symptom and not the cause. Worse, read-tree is not atomic: by
# the time it hits the unwritable path it has already rewritten other files, so
# the worktree is left half-deployed. Checking first costs one find.
#
# NOTE: this hook runs with the cwd set to the .git DIRECTORY, not the worktree
# -- \`git rev-parse --show-toplevel\` does not help during a push either, which is
# why the path is baked in at install time, the same as in post-receive. Scanning
# "." here would quietly scan .git and always pass.
me="\$(id -un)"
bad="\$(find "$WORKTREE" -path "$WORKTREE/.git" -prune -o ! -user "\$me" -print 2>/dev/null | head -5)"
if [ -n "\$bad" ]; then
  echo "  !! REFUSING TO DEPLOY: paths in the worktree are not owned by \$me:" >&2
  echo "\$bad" | sed 's/^/       /' >&2
  echo "     These are leftovers from a sudo run. Move them into the state" >&2
  echo "     directory -- they do not belong in the worktree (docs/run.md):" >&2
  echo "       sudo mv arms ~/gvpn-state/arms-old" >&2
  echo "       sudo mv bench-runs/* ~/gvpn-state/runs/ && sudo rmdir bench-runs" >&2
  echo "       sudo chown -R \$me: ~/gvpn-state" >&2
  exit 1
fi
git update-index -q --refresh
# --reset makes the pushed tree authoritative for TRACKED paths, replacing a
# stale hand-copied file even though it is currently untracked. Paths that are
# not in the tree are left exactly as they are.
git read-tree -u --reset "\$1"
HOOK
  chmod +x "$GITDIR/hooks/push-to-checkout"
  write_post_receive "$GITDIR/hooks"
  echo "    installed"
  REMOTE_PATH="$WORKTREE"
else
  say "bare repo at $BARE"
  [ -d "$BARE" ] && echo "    already exists" \
                 || { git init --bare --quiet --initial-branch="$BRANCH" "$BARE"; echo "    created"; }
  say "post-receive hook"
  cat > "$BARE/hooks/post-receive" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -e "$GVPN_RUN_LOCK" ]; then
  echo "  !! NOT deploying: a benchmark run is in progress" >&2
  echo "     \$(readlink "$GVPN_RUN_LOCK" 2>/dev/null)" >&2
  echo "     The push was stored; re-push after the run, or: rm $GVPN_RUN_LOCK" >&2
  exit 0
fi
while read -r _old _new ref; do
  [ "\$ref" = "refs/heads/$BRANCH" ] || continue
  mkdir -p "$WORKTREE"
  git --work-tree="$WORKTREE" --git-dir="$BARE" checkout -f "$BRANCH"
done
EOF
  cat >> "$BARE/hooks/post-receive" <<EOF
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
cd "$WORKTREE" || exit 0
chmod +x setup/*.sh bench/*.sh bench/*.py 2>/dev/null || true
for f in setup/*.sh bench/*.sh; do [ -f "\$f" ] && { bash -n "\$f" || echo "  !! SYNTAX ERROR in \$f"; }; done
echo "  deployed $BRANCH -> $WORKTREE"
EOF
  chmod +x "$BARE/hooks/post-receive"
  echo "    installed"
  REMOTE_PATH="$BARE"
fi

HOSTPART="$(id -un)@$(hostname -I 2>/dev/null | awk '{print $1}')"

cat <<EOF

==> Done. On your Mac, from your local copy of the kit:

    cd /path/to/gvpn-8408
    git init -b $BRANCH                       # if it is not a repo yet
    git add -A && git commit -m "kit"
    git remote add vm "$HOSTPART:$REMOTE_PATH"
    git push -u vm $BRANCH

With an SSH config alias (docs/run.md), nicer as:

    git remote set-url vm gvpn-vm:$REMOTE_PATH

Thereafter:  edit -> git commit -> git push vm $BRANCH

REPLACED BY A DEPLOY (tracked):  setup/ bench/ lib/ tools/ tests/ docs/
                                 arms/ (TEMPLATES only) studies/ results/
                                 Makefile README.md gvpn.conf
OUT OF REACH ENTIRELY:           $GVPN_STATE -- runs, rendered arms, secrets,
                                 identity backups. Outside the worktree, so no
                                 deploy and no \`git clean\` can touch them.

A PUSH IS REJECTED while $GVPN_RUN_LOCK exists, i.e. while a benchmark is
running. That is deliberate: a deploy rewrites script files in place and bash
reads a script as it executes.

Make sure your LOCAL copy is current before the first push -- it becomes the
source of truth for every tracked file on this machine.
EOF
