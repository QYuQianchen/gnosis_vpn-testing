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
#   docs/design.md, committing a report with a peer ID in a log excerpt, or adding a
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
# PORTABILITY: this is the one script in the kit that runs on a laptop as well as
# on the VM, because it is wired in as a pre-commit hook. macOS still ships bash
# 3.2 (the last GPLv2 release), so no `mapfile`, no associative arrays, and no
# `${var^^}`. Keep it to bash 3.2 and to flags BSD and GNU both understand -- a
# pre-commit hook that errors is a pre-commit hook everyone disables.
set -uo pipefail

MODE=staged
case "${1:-}" in
  --tracked)  MODE=tracked ;;
  -h|--help)  sed -n '2,45p' "$0"; exit 0 ;;
  "")         ;;
  *)          echo "unknown option: $1" >&2; exit 2 ;;
esac

ALLOW='scan-secrets: allow'

# Deliberately not anchored: an address is just as dangerous mid-sentence.
# A match on one of these IS an address or a key. There is no way to tell a
# "placeholder" 40-hex string from a real one by looking at it, so nothing
# exempts these except an explicit allow marker on the line. An earlier version
# tried to be clever -- it treated a line as benign if it contained a shell
# variable or one of a few known placeholder prefixes -- and that let
# `0xdeadbeef...` through, because the prefix `0xdead` was on the list. The test
# that caught it is in this file's header. Per-line heuristics over per-match
# ones are how a scanner develops a blind spot.
VALUE_PATTERNS=(
  '0x[0-9a-fA-F]{64}'
  '0x[0-9a-fA-F]{40}'
  '(12D3Koo|16Uiu2H)[A-Za-z0-9]{20,}'
)

# The KEY on its own, for a file that names an address without one being visible
# (a truncated log, a template). Here a placeholder value is genuinely common --
# the generator writes `safe_address: "$SAFE_ADDR"` and the templates carry
# `@RELAY@` -- so this one pattern does take the exemptions below.
KEY_PATTERN='^[[:space:]]*(safe|module)_address[[:space:]]*:'
KEY_BENIGN='\$[A-Za-z_{]|@[A-Z_]+@|FILL_ME_IN|<[A-Za-z_]+>'

list_files() {
  if [ "$MODE" = tracked ]; then
    git ls-files
  else
    git diff --cached --name-only --diff-filter=ACMR
  fi
}

# A newline-separated string rather than an array: bash 3.2 has no mapfile, and
# expanding an empty array under `set -u` is an error there too. Filenames with
# newlines would break this, but git does not produce them here and a commit
# containing one is its own problem.
#
# The file list comes in on fd 3, not stdin: the inner loop below reads the
# matching lines on stdin, and sharing one descriptor between two nested loops
# is how a scan silently stops after its first file.
hits=0
while IFS= read -r f <&3; do
  [ -n "$f" ] || continue
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
    for p in "${VALUE_PATTERNS[@]}"; do
      grep -nE "$p" "$f" 2>/dev/null
    done
    # Key lines are reported only when the value is not a placeholder.
    grep -nE "$KEY_PATTERN" "$f" 2>/dev/null | grep -vE "$KEY_BENIGN"
  )
  found=$(printf '%s\n' "$found" | sort -t: -k1,1n -u)
  [ -n "$found" ] || continue

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *"$ALLOW"*) continue ;; esac
    printf '  %s:%s\n' "$f" "$line"
    hits=$((hits + 1))
  done <<< "$found"
done 3< <(list_files)

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
