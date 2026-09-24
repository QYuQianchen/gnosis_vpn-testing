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

# canary: the checker must still catch the bug it exists for
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/bash\nset -u\nRUN_LOG=x\ntouch "$CODES_LEDGER"\n: > "$RUN_LOG"\n' > "$TMP/canary.sh"
python3 tests/unbound.py "$TMP/canary.sh" >/dev/null \
  && { printf '  FAIL  the checker missed a planted unassigned variable\n'; fail=1; } \
  || printf '  ok    the checker catches a planted unassigned variable\n'

echo; [ "$fail" = 0 ] && echo "all lint tests passed" || echo "FAILURES above"; exit $fail
