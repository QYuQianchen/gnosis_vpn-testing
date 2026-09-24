#!/usr/bin/env bash
#
# run-analyze-tests.sh -- exercise the report against fabricated runs.
#
#   ./tests/run-analyze-tests.sh
#
# The analyser is the only part of this kit whose output anyone will quote, and
# the only part that cannot be checked by running it once on the VM: a real run
# produces one dataset, and the interesting cases are the ones you hope never to
# see. So the cases are fabricated:
#
#   win      a clear improvement over three exits  -> must read as a result
#   null     arms that differ only by noise        -> must NOT read as a result
#   broken   the pinned arm still drawing many routes
#                                                  -> must refuse to report at all
#
# The third is the one that matters. A run where the planner override never
# loaded produces perfectly plausible tables comparing 'auto' with itself, and
# nothing in the numbers says so.
#
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

check() {  # check SCENARIO PATTERN DESCRIPTION
  local scen="$1" pat="$2" desc="$3"
  if grep -qE "$pat" "$TMP/$scen.out"; then
    printf '  ok    %-8s %s\n' "$scen" "$desc"
  else
    printf '  FAIL  %-8s %s\n' "$scen" "$desc"
    fail=1
  fi
}

for scen in win null broken thin; do
  python3 "$KIT/tests/mkrun.py" "$TMP/run-$scen" "$scen" >/dev/null
  python3 "$KIT/bench/gvpn-analyze.py" "$TMP/run-$scen" \
          --floor-mbps 5 --markdown "$TMP/$scen.md" > "$TMP/$scen.out"
done

check win    'RAISES the performance floor'   'reports a win'
check win    'pin-planner +'                  'names the winning arm'
check win    '1\.0'                           'pinned arm shows one route'
check null   'NOT conclusive|No measurable'   'declines to claim a result'
check broken 'THE PIN DID NOT TAKE'           'refuses the whole run'
check broken 'CAVEATS'                      'lists the caveat on the console'
# Five arms x five cycles is below the 8 samples a bootstrap CI needs, so every
# interval comes back empty and the report must say so rather than quoting the
# point estimates -- which at n=5 include a sign-flipped arm.
check thin   'Too few sessions|NOT conclusive' 'declines at 5 cycles'
check thin   'Smallest arm has 5 usable'       'names the sample size in a caveat'

# A trial is a rehearsal, so its report must refuse to score the arms EVEN when
# the data shows a huge effect -- the failure this guards against is a
# rehearsal's report being pasted into the issue as if it were the study.
python3 - "$TMP/run-win" <<'EOF'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]) / "manifest.json"
m = json.loads(p.read_text()); m["trial"] = True
p.write_text(json.dumps(m))
EOF
python3 "$KIT/bench/gvpn-analyze.py" "$TMP/run-win" --floor-mbps 5 > "$TMP/trial.out"
check trial  'TRIAL RUN'                       'refuses to score a trial run'
grep -q 'RAISES the performance floor' "$TMP/trial.out" \
  && { printf '  FAIL  trial    still claimed a win\n'; fail=1; } \
  || printf '  ok    trial    suppresses the win it would otherwise report\n'

grep -q 'WARNING' "$TMP/broken.md" || { printf '  FAIL  broken   markdown carries the warning\n'; fail=1; }
grep -q 'slow 10%' "$TMP/win.md"   || { printf '  FAIL  win      markdown has the headline table\n'; fail=1; }

echo
[ "$fail" = 0 ] && echo "all analyzer tests passed" || echo "FAILURES above"
exit $fail
