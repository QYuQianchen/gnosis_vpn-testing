#!/usr/bin/env bash
#
# scan-secrets.sh -- refuse to commit anything that identifies this node.
#
#   ./tools/scan-secrets.sh            scan what is staged (what pre-commit runs)
#   ./tools/scan-secrets.sh --tracked  scan every tracked file (audit an old repo)
#
# WHAT THIS IS ACTUALLY FOR
#
#   Keeping generated arms and faucet codes outside the repo handles the obvious
#   path. It does not handle the realistic one: pasting a journalctl extract into
#   docs/plan.md, committing a report with a peer ID in a log excerpt, or adding a
#   "just this once" hopr.yaml while debugging at 1am. Those arrive through files
#   that are supposed to be tracked, so no .gitignore can catch them.
#
#   This is a blunt instrument on purpose. False positives cost you one --no-verify
#   or one allowlist line; a false negative is a node identity in a repo's history,
#   which survives deletion of the file.
#
# WHAT IT LOOKS FOR
#
#   0x-prefixed 40-hex addresses   safe, module, node and relay addresses
#   12D3Koo... / 16Uiu2H...        libp2p peer IDs
#   0x-prefixed 64-hex             private keys and identity material
#   gnosisvpn-hopr.safe contents   safe_address:/module_address: lines
#   faucet codes                   the documented code shape
#
# ALLOWLIST
#
#   A line ending in the marker below is exempt -- use it for the placeholder
#   addresses in documentation and templates, and nothing else:
#
#       safe_address: "0xFILL_ME_IN"   # scan-secrets: allow
#
set -uo pipefail

MODE=staged
[ "${1:-}" = "--tracked" ] && MODE=tracked
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '2,40p' "$0"; exit 0; }

ALLOW='scan-secrets: allow'

# Deliberately not anchored: an address is just as dangerous mid-sentence.
PATTERNS=(
  '0x[0-9a-fA-F]{64}'
  '0x[0-9a-fA-F]{40}'
  '\b(12D3Koo|16Uiu2H)[A-Za-z0-9]{20,}'
  '^\s*(safe|module)_address\s*:'
)

# Lines that match a pattern but are obviously not an address. Without this the
# generator's own `safe_address: "$SAFE_ADDR"` trips the scan on every commit,
# and a check that cries wolf every time is a check people learn to bypass with
# --no-verify -- which is worse than not having it.
BENIGN='\$[A-Za-z_{]|@[A-Z_]+@|FILL_ME_IN|0x\.\.\.|0xRELAY|0xdead|<[A-Za-z_]+>'

if [ "$MODE" = tracked ]; then
  mapfile -t FILES < <(git ls-files)
else
  mapfile -t FILES < <(git diff --cached --name-only --diff-filter=ACMR)
fi
[ "${#FILES[@]}" -gt 0 ] || exit 0

hits=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    tools/scan-secrets.sh) continue ;;          # this file describes the patterns
  esac
  # Binary files: git would have refused to diff them usefully anyway.
  grep -Iq . "$f" 2>/dev/null || continue

  # Collect across all patterns first, then report each LINE once. A real address
  # matches several patterns, and printing it three times makes a two-problem
  # commit look like a six-problem one.
  found=$(
    for p in "${PATTERNS[@]}"; do
      grep -nE "$p" "$f" 2>/dev/null
    done | sort -t: -k1,1n -u
  )
  [ -n "$found" ] || continue

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *"$ALLOW"*) continue ;; esac
    printf '%s' "$line" | grep -qE "$BENIGN" && continue
    printf '  %s:%s\n' "$f" "$line"
    hits=$((hits + 1))
  done <<< "$found"
done

if [ "$hits" -gt 0 ]; then
  cat >&2 <<EOF

REFUSING TO COMMIT: $hits line(s) look like node identity or an address.

Listed above. If one is a genuine placeholder or an example, mark that line:

    ... # $ALLOW

If it is real, it belongs in the state directory (\$GVPN_STATE, ~/gvpn-state by
default), which is outside this repo on purpose. Note that
\`git add -p\`-ing it away is not enough once it has been committed -- the
object stays in the history.

To override for one commit (you should have a reason):  git commit --no-verify
EOF
  exit 1
fi
exit 0
