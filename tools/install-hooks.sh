#!/usr/bin/env bash
#
# install-hooks.sh -- point this clone's hooks at the tracked ones.
#
#   ./tools/install-hooks.sh
#
# Run once per clone, on every machine that COMMITS -- your laptop above all.
# Git does not sync hooks, which is the whole reason the check lives in a tracked
# script and the hook is a two-line shim pointing at it: the logic is reviewable
# and versioned, and only the wiring is per-clone.
#
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$(git -C "$KIT" rev-parse --git-path hooks)"
[ -d "$HOOKS" ] || { echo "not a git repo: $KIT" >&2; exit 1; }

cat > "$HOOKS/pre-commit" <<'EOF'
#!/bin/sh
exec "$(git rev-parse --show-toplevel)/tools/scan-secrets.sh"
EOF
chmod +x "$HOOKS/pre-commit"

echo "installed pre-commit -> tools/scan-secrets.sh in $HOOKS"
echo
echo "Checking what is already tracked, in case something predates the hook:"
"$KIT/tools/scan-secrets.sh" --tracked && echo "  clean."
