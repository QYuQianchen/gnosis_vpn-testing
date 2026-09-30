#!/usr/bin/env bash
# Static checks every script must pass: bash syntax, and no variable used
# without a default that nothing assigns (under `set -u` that aborts the script
# mid-run -- which shipped once, in gvpn-bench.sh, after a refactor).
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$KIT"
fail=0
echo "lint"
for f in bench/*.sh setup/*.sh tools/*.sh tests/*.sh lib/*.sh; do
  bash -n "$f" 2>/dev/null || { printf '  FAIL  syntax: %s\n' "$f"; fail=1; }
done
[ "$fail" = 0 ] && printf '  ok    every script parses\n'

if out="$(python3 tests/unbound.py bench/*.sh setup/*.sh tools/*.sh lib/common.sh)"; then
  printf '  ok    no variable used unassigned\n'
else
  printf '  FAIL  variables used without a default and never assigned:\n%s\n' "$out"; fail=1
fi

# A literal "{...}" inside a ${VAR:-default} closes the expansion at its "}" and
# appends a stray "}" -- every download URL of three runs ended in "}".
hits="$(grep -nE '\$\{[A-Za-z_][A-Za-z0-9_]*:?[-=+][^}$]*\{' bench/*.sh setup/*.sh tools/*.sh lib/*.sh || true)"
[ -z "$hits" ] && printf '  ok    no literal brace inside a ${VAR:-default}\n' \
  || { printf '  FAIL  literal brace inside a ${VAR:-default} (the "}" ends the expansion):\n%s\n' "$hits"; fail=1; }

# canary: the checker must still catch the bug it exists for
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/bash\nset -u\nRUN_LOG=x\ntouch "$CODES_LEDGER"\n: > "$RUN_LOG"\n' > "$TMP/canary.sh"
python3 tests/unbound.py "$TMP/canary.sh" >/dev/null \
  && { printf '  FAIL  the checker missed a planted unassigned variable\n'; fail=1; } \
  || printf '  ok    the checker catches a planted unassigned variable\n'
# ...and a kit variable used by a script that never sources lib/common.sh (05-set-version.sh)
printf '#!/bin/bash\nset -u\necho "$GVPN_STATE/BUILD.txt"\n' > "$TMP/nosource.sh"
python3 tests/unbound.py "$TMP/nosource.sh" >/dev/null \
  && { printf '  FAIL  the checker missed a kit variable in a script that does not source common.sh\n'; fail=1; } \
  || printf '  ok    kit variables count only where lib/common.sh is sourced\n'

echo; [ "$fail" = 0 ] && echo "all lint tests passed" || echo "FAILURES above"; exit $fail
