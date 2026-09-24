#!/usr/bin/env bash
#
# faucet-codes.sh -- what happened to every faucet code.
#
#   ./tools/faucet-codes.sh            summary: how many left, what was spent
#   ./tools/faucet-codes.sh --ledger   every attempt, with the faucet's answer
#   ./tools/faucet-codes.sh --release CODE   put a code back in circulation
#
# WHY THIS IS NOT JUST `cat faucet-codes.used`
#
#   That file answers one question -- may this code be offered again -- and it
#   cannot distinguish a code that funded a node from one the faucet refused.
#   When a run has consumed three codes and produced two identities, the
#   difference is the whole story, so gvpn-bench.sh also writes a ledger:
#
#     <timestamp>  <code>  accepted|rejected|transport-error  <detail>
#
#   Codes are shown truncated. They are single-use and mostly spent, but a live
#   one is money and this output tends to end up pasted into chat.
#
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$KIT/lib/common.sh"

CODES="${GVPN_CODES_FILE:-$GVPN_SECRETS_DIR/faucet-codes}"
USED="${GVPN_USED_CODES:-$GVPN_SECRETS_DIR/faucet-codes.used}"
LEDGER="${GVPN_CODES_LEDGER:-$GVPN_SECRETS_DIR/faucet-codes.log}"

MODE=summary
RELEASE=""
case "${1:-}" in
  --ledger) MODE=ledger ;;
  --release) MODE=release; RELEASE="${2:?--release needs a code}" ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

mask() { sed -E 's/^(.{4}).*(.{2})$/\1…\2/'; }

# Real codes only: blanks and comments are not codes.
live_codes() { grep -vE '^\s*($|#)' "$CODES" 2>/dev/null || true; }

if [ ! -r "$CODES" ]; then
  cat <<EOF
No faucet-codes file at:
  $CODES

That is fine unless you plan to run a pin-cfg-* arm -- those are the only arms
that re-onboard, and they are not in the default study. To add codes:

  install -m 600 /dev/null $CODES
  \$EDITOR $CODES        # one code per line, # for comments
EOF
  exit 0
fi

if [ "$MODE" = release ]; then
  if ! grep -Fxq "$RELEASE" "$USED" 2>/dev/null; then
    echo "not in $USED -- nothing to release"; exit 1
  fi
  grep -Fxv "$RELEASE" "$USED" > "$USED.tmp" && mv "$USED.tmp" "$USED"
  echo "released $(printf '%s' "$RELEASE" | mask); it will be offered again."
  echo "Only do this for a code the faucet never actually answered for --"
  echo "check with --ledger first. Re-offering a spent code just burns an arm."
  exit 0
fi

if [ "$MODE" = ledger ]; then
  if [ ! -s "$LEDGER" ]; then
    echo "No ledger yet at $LEDGER -- no onboarding has run."
    exit 0
  fi
  printf '%-20s  %-10s  %-16s  %s\n' TIMESTAMP CODE OUTCOME DETAIL
  printf '%s\n' "$(printf '%.0s-' {1..78})"
  while IFS=$'\t' read -r ts code outcome detail; do
    printf '%-20s  %-10s  %-16s  %s\n' \
      "$ts" "$(printf '%s' "$code" | mask)" "$outcome" "${detail:0:34}"
  done < "$LEDGER"
  exit 0
fi

# ------------------------------------------------------------------ summary --

TOTAL=$(live_codes | wc -l | tr -d ' ')
USED_N=$(grep -cvE '^\s*$' "$USED" 2>/dev/null || echo 0)
# `grep -f` against a missing or empty pattern file matches nothing and reports
# failure, which would silently make "still available" read 0 on a fresh setup --
# the exact number someone checks before starting a run.
if [ -s "$USED" ]; then
  REMAIN=$(live_codes | grep -Fxv -f "$USED" | wc -l | tr -d ' ')
else
  REMAIN=$TOTAL
fi

printf '\nfaucet codes  %s\n' "$CODES"
printf '  %-28s %s\n' "in the file"   "$TOTAL"
printf '  %-28s %s\n' "consumed"      "$USED_N"
printf '  %-28s %s\n' "still available" "$REMAIN"

if [ -s "$LEDGER" ]; then
  A=$(awk -F'\t' '$3=="accepted"' "$LEDGER" | wc -l | tr -d ' ')
  R=$(awk -F'\t' '$3=="rejected"' "$LEDGER" | wc -l | tr -d ' ')
  T=$(awk -F'\t' '$3=="transport-error"' "$LEDGER" | wc -l | tr -d ' ')
  printf '\nattempts recorded in %s\n' "$LEDGER"
  printf '  %-28s %s\n' "accepted (funded a node)" "$A"
  printf '  %-28s %s\n' "rejected by the faucet"   "$R"
  printf '  %-28s %s\n' "faucet unreachable"       "$T"
  if [ "${T:-0}" -gt 0 ]; then
    cat <<EOF

  $T attempt(s) never reached the faucet. Those codes were NOT consumed and are
  still in circulation -- the arm failed, but nothing was spent. See --ledger.
EOF
  fi
  if [ "${R:-0}" -gt 0 ]; then
    cat <<EOF

  $R code(s) were refused. The usual reason is that the code was already
  redeemed elsewhere. They are marked used so a later cycle does not burn an arm
  retrying them; --ledger has the faucet's own answer.
EOF
  fi
else
  printf '\nNo attempts recorded yet -- nothing has re-onboarded.\n'
fi

if [ "$REMAIN" -eq 0 ] && [ "$TOTAL" -gt 0 ]; then
  cat <<EOF

NO CODES LEFT. A pin-cfg-* arm will fail at its first cycle. The default study
(auto, pin-planner, no-explore) does not need any.
EOF
fi
echo
