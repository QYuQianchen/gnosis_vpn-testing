#!/usr/bin/env bash
# preflight.sh -- prove every arm can run, calibrate the floor, then launch.
#
# The point of this script is that you walk away afterwards. Everything it
# checks is something that, left unchecked, produces a run that LOOKS fine for
# hours and turns out to be worthless: an arm whose yaml never loaded, a pin
# that did not take, a floor threshold chosen after the fact, a client that
# upgraded itself mid-study.
#
#   sudo -E ./bench/preflight.sh --study NAME
#       checks, runs a TRIAL of the study, calibrates the floor -- stops there.
#
#   sudo -E ./bench/preflight.sh --study NAME --launch
#       the same, and if everything passes, launches the FULL study detached.
#
#   sudo -E ./bench/preflight.sh --study NAME --trial-only
#       just the checks and the trial. No calibration, nothing launched.
#
# It exits non-zero on the first hard failure, so --launch cannot fire after a
# failed check. Every stage says what to do when it fails.

set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT/lib/common.sh"

STUDY=""
LAUNCH=0
ARMS_OVERRIDE=""
CAL_CYCLES=8
PIN_CURRENT=0
SKIP_TRIAL=0
SKIP_CAL=0
TRIAL_ONLY=0
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: sudo -E $0 --study NAME [--launch] [options]

  --study NAME          study file in studies/ (without .conf)
  --launch              launch the study detached if every check passes
  --arms "a b c"        override the study's arm list for the checks
  --calibrate-cycles N  baseline-only cycles for the floor (default $CAL_CYCLES)
  --pin-current         write the currently-installed client version into the
                        study file as GVPN_PIN_VERSION, then continue
  --trial-only          stop after the trial: checks + one small run, nothing else
  --skip-trial          skip stage C
  --skip-calibrate      skip stage D; the study must already set GVPN_FLOOR_MBPS
  -y                    do not pause before launching

Stages:
  A  static checks          seconds
  B  per-arm route gate     ~3 min per arm  -- proves each arm's config loads
  C  TRIAL run              ~1 min per arm  -- the study at 1 cycle x 5 MB,
                            same arms and exits, end to end through the report
  D  floor calibration      ~${CAL_CYCLES} x 3 min, baseline arm only
  E  launch the FULL study  detached; returns immediately

A trial is the study shrunk, not a different study: same arms, same exits, same
load source. A smaller --profile would exercise a different configuration, which
is how a rehearsal passes and the real run fails on its first cycle.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --study)             STUDY="$2"; shift 2 ;;
    --launch)            LAUNCH=1; shift ;;
    --arms)              ARMS_OVERRIDE="$2"; shift 2 ;;
    --calibrate-cycles)  CAL_CYCLES="$2"; shift 2 ;;
    --pin-current)       PIN_CURRENT=1; shift ;;
    --trial-only)        TRIAL_ONLY=1; shift ;;
    --skip-trial)        SKIP_TRIAL=1; shift ;;
    --skip-calibrate)    SKIP_CAL=1; shift ;;
    -y|--yes)            ASSUME_YES=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$STUDY" ] || { echo "--study is required" >&2; usage >&2; exit 2; }
STUDY_FILE="$KIT/studies/$STUDY.conf"
[ -f "$STUDY_FILE" ] || { echo "no such study: $STUDY_FILE" >&2; exit 2; }

# shellcheck disable=SC1090
. "$STUDY_FILE"

ARMS="${ARMS_OVERRIDE:-${GVPN_ARMS:-}}"
[ -n "$ARMS" ] || { echo "study sets no GVPN_ARMS and none given" >&2; exit 2; }
BASELINE="${GVPN_BASELINE:-auto}"
CTL="${GVPN_CTL:-gnosis_vpn-ctl}"

LOG="$GVPN_STATE/preflight-$(date -u +%Y%m%dT%H%M%SZ).log"
mkdir -p "$GVPN_STATE"
exec > >(tee -a "$LOG") 2>&1

fails=0; warns=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; warns=$((warns+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails+1)); }
note() { printf '        %s\n' "$*"; }
stage(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mSTOPPED\033[0m  %s\n' "$*"; exit 1; }

printf '\npreflight for study "%s"\n' "$STUDY"
printf 'arms: %s\nlog:  %s\n' "$(echo $ARMS)" "$LOG"

# ============================================================== STAGE A ====
stage "A  static checks"

[ "$(id -u)" = 0 ] || bad "not root -- use sudo -E (arms install into /etc)"

# A pin-cfg arm needs the node's channels trimmed to one relay, which is
# node-global. Mixed into an ordinary study it silently contaminates every other
# arm, so this is a refusal rather than a warning.
for a in $ARMS; do
  case "$a" in
    pin-cfg-*) bad "'$a' cannot run in a normal study -- it needs the channel set trimmed."
               note "That is study 2. See docs/running-all-arms.md." ;;
  esac
done

for a in $ARMS; do
  if [ -d "$GVPN_ARMS_DIR/$a" ]; then
    pass "arm '$a' is rendered"
  else
    bad "arm '$a' not in $GVPN_ARMS_DIR -- run: sudo -E ./setup/02-make-arms.sh"
  fi
done

if grep -rlE 'FILL_ME_IN|@RELAY@|@MIN_ACK_RATE@' "$GVPN_ARMS_DIR" >/dev/null 2>&1; then
  bad "unsubstituted placeholders in rendered arms:"
  grep -rlE 'FILL_ME_IN|@RELAY@|@MIN_ACK_RATE@' "$GVPN_ARMS_DIR" | sed 's/^/        /'
  note "The node had not onboarded when make arms ran. Re-run it."
else
  pass "no unsubstituted placeholders in rendered arms"
fi

if systemctl is-active --quiet gnosisvpn; then
  pass "gnosisvpn service is active"
else
  bad "gnosisvpn service is not active -- systemctl status gnosisvpn"
fi

# An unpinned version is the single most expensive silent failure available: the
# client upgrades mid-study and the run compares versions instead of arms.
INSTALLED="$(dpkg-query -W -f='${Version}' gnosis-vpn-client 2>/dev/null || true)"

# Pinning has to be a deliberate act -- but TYPING the version is not, and a
# string like 2026.09.17+build.134506 is exactly the kind a transcription error
# survives unnoticed until the manifest is read weeks later.
if [ "$PIN_CURRENT" = 1 ]; then
  if [ -z "$INSTALLED" ]; then
    bad "--pin-current but no gnosis-vpn-client package is installed"
  else
    if grep -q '^GVPN_PIN_VERSION=' "$STUDY_FILE"; then
      sed -i "s|^GVPN_PIN_VERSION=.*|GVPN_PIN_VERSION=$INSTALLED|" "$STUDY_FILE"
    else
      printf '\nGVPN_PIN_VERSION=%s\n' "$INSTALLED" >> "$STUDY_FILE"
    fi
    GVPN_PIN_VERSION="$INSTALLED"
    pass "pinned the study at the installed version $INSTALLED"
    note "written into $STUDY_FILE -- commit it"
  fi
fi

if [ -z "${GVPN_PIN_VERSION:-}" ]; then
  bad "the study sets no GVPN_PIN_VERSION (installed: ${INSTALLED:-unknown})"
  note "Without it each arm installs whatever is newest when it runs, and the"
  note "tables look completely normal. Either:"
  note "  sudo -E $0 --study $STUDY --pin-current      (pins at ${INSTALLED:-the installed version})"
  note "  sudo ./setup/05-set-version.sh --list        (pick a different one)"
elif [ "$INSTALLED" = "$GVPN_PIN_VERSION" ]; then
  pass "client pinned at $INSTALLED"
else
  bad "installed $INSTALLED but study pins $GVPN_PIN_VERSION"
  note "Run: sudo ./setup/05-set-version.sh $GVPN_PIN_VERSION"
fi

if printf '%s\n' $ARMS | grep -qx zero-hop; then
  if systemctl show gnosisvpn -p ExecStart | grep -q -- --allow-insecure; then
    pass "--allow-insecure present (zero-hop needs it)"
  else
    bad "zero-hop is in the arm list but the service has no --allow-insecure"
    note "Re-run: sudo ./setup/00-vm-setup.sh --allow-insecure"
  fi
fi

# Without planner DEBUG there are no candidate-path lines, so stage B cannot
# tell a genuine pin of 1 from a count of nothing.
if systemctl show gnosisvpn -p Environment | tr ' ' '\n' | grep -q 'RUST_LOG.*path'; then
  pass "planner DEBUG logging is on"
else
  bad "planner DEBUG logging is off -- route counts will be impossible"
  note "00-vm-setup.sh installs it as 10-bench-logging.conf."
fi

# The policy route is what keeps your SSH session alive when the tunnel takes
# the default route. A rule pointing at an EMPTY table is the worst state,
# because it looks configured and protects nothing.
if ip rule show 2>/dev/null | grep -q 200 && [ -n "$(ip route show table 200 2>/dev/null)" ]; then
  pass "policy route present and table 200 is non-empty"
else
  bad "policy route missing or table 200 is empty -- a connect may take your SSH"
  note "ip rule show | grep 200 ; ip route show table 200   (BOTH must be non-empty)"
  note "Keep the Contabo console open before going further."
fi

FREE_GB=$(df -BG --output=avail "$GVPN_STATE" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 20 ]; then
  warn "only ${FREE_GB}G free in $GVPN_STATE -- planner DEBUG runs ~100 MB/hour"
else
  pass "disk space ok (${FREE_GB:-?}G free)"
fi

if [ -e "$GVPN_RUN_LOCK" ]; then
  bad "a run is already in progress ($GVPN_RUN_LOCK -> $(readlink -f "$GVPN_RUN_LOCK" 2>/dev/null))"
  note "make status ; remove the lock only if it is stale."
else
  pass "no run in progress"
fi

[ "$fails" -eq 0 ] || die "$fails static check(s) failed. Nothing has been run."

# ============================================================== STAGE B ====
stage "B  per-arm route gate  (~3 min per arm)"
note "Installs each arm and counts distinct routes. This is what catches an arm"
note "whose yaml never loaded -- HoprLibConfig is deny_unknown_fields, so a typo"
note "stops the service rather than being ignored."

declare -A ROUTES=()
for a in $ARMS; do
  printf '\n  --- %s ---\n' "$a"
  out="$("$KIT/bench/use-arm.sh" "$a" --count 2>&1)"
  echo "$out" | sed 's/^/  /'
  n="$(printf '%s' "$out" | sed -n 's/.*drew from \([0-9][0-9]*\) distinct route.*/\1/p' | tail -1)"
  if [ -z "$n" ]; then
    bad "arm '$a' produced no route count"
    continue
  fi
  ROUTES[$a]="$n"
done

printf '\n'
for a in $ARMS; do
  n="${ROUTES[$a]:-}"
  [ -n "$n" ] || continue
  case "$a" in
    pin-planner|zero-hop)
      if [ "$n" -eq 1 ]; then pass "$a drew 1 route (pinned, as designed)"
      else bad "$a drew $n routes, expected 1 -- the manual hopr config is not being read"
           note "check /etc/systemd/system/gnosisvpn.service.d/30-arm.conf" ; fi ;;
    narrow)
      if [ "$n" -le 3 ]; then pass "$a drew $n route(s) (cap is 3)"
      else bad "$a drew $n routes, expected <=3" ; fi ;;
    "$BASELINE"|auto|no-explore)
      if [ "$n" -gt 1 ]; then pass "$a drew $n routes (free, as designed)"
      else bad "$a drew $n route -- the baseline has no path diversity to lose"
           note "The node likely holds one channel. Every comparison would be void."
           note "Check the channel count before running anything." ; fi ;;
    *)
      pass "$a drew $n route(s)" ;;
  esac
done

[ "$fails" -eq 0 ] || die "$fails arm(s) failed the route gate. Nothing long has been run."

# ============================================================== STAGE C ====
if [ "$SKIP_TRIAL" = 1 ]; then
  stage "C  trial run  (skipped)"
else
  stage "C  TRIAL -- the whole study at 1 cycle x 5 MB  (~1 min per arm)"
  note "Stage B proved each arm's config loads. This proves the rest of the"
  note "pipeline: data moves through the tunnel, the interleaving works, every"
  note "arm produces a usable session, and the report renders."

  GVPN_ARMS="$ARMS" GVPN_STUDY="$STUDY" \
    "$KIT/bench/gvpn-bench.sh" --trial || die "trial run failed"

  TRIAL_RUN="$(ls -1dt "$GVPN_RUNS_DIR"/*/ 2>/dev/null | head -1)"; TRIAL_RUN="${TRIAL_RUN%/}"
  if [ -f "$TRIAL_RUN/summary.csv" ]; then
    printf '\n'
    for a in $ARMS; do
      ok=$(awk -F, -v a="$a" 'NR>1 && $2==a && $NF=="ok"' "$TRIAL_RUN/summary.csv" | wc -l)
      want=$(printf '%s\n' ${GVPN_DESTINATIONS:-${GVPN_DESTINATION:-one}} | grep -c .)
      if [ "$ok" -ge "$want" ]; then
        pass "$a completed $ok/$want session(s) with data"
      else
        bad "$a completed only $ok of $want expected session(s)"
        note "see $TRIAL_RUN"
      fi
    done
  else
    bad "trial run produced no summary.csv ($TRIAL_RUN)"
  fi
  [ "$fails" -eq 0 ] || die "$fails arm(s) failed the trial."

  # Render the report too. A trial that cannot be read is only half a rehearsal,
  # and the analyzer marks a trial as un-scoreable so this can never be mistaken
  # for the study's result.
  python3 "$KIT/bench/gvpn-analyze.py" "$TRIAL_RUN" --no-diagnostics \
          --markdown "$TRIAL_RUN/report.md" >/dev/null \
    && pass "report renders ($TRIAL_RUN/report.md)" \
    || bad "the analyzer could not read the trial run"
fi

if [ "$TRIAL_ONLY" = 1 ]; then
  printf '\n'
  [ "$warns" -eq 0 ] && pass "trial complete -- every arm ran through" \
                     || warn "trial complete with $warns warning(s)"
  cat <<EOF

  --trial-only: stopping here. Nothing calibrated, nothing launched.

  When ready:
      sudo -E $0 --study $STUDY --launch -y
EOF
  exit 0
fi

# ============================================================== STAGE D ====
if [ "$SKIP_CAL" = 1 ]; then
  stage "D  floor calibration  (skipped)"
  [ -n "${GVPN_FLOOR_MBPS:-}" ] || die "--skip-calibrate but the study sets no GVPN_FLOOR_MBPS"
  pass "study already declares GVPN_FLOOR_MBPS=$GVPN_FLOOR_MBPS"
elif [ -n "${GVPN_FLOOR_MBPS:-}" ]; then
  stage "D  floor calibration  (already set)"
  pass "study declares GVPN_FLOOR_MBPS=$GVPN_FLOOR_MBPS -- leaving it alone"
  note "Re-calibrating after a study starts would move the headline number."
else
  stage "D  floor calibration -- '$BASELINE' alone, $CAL_CYCLES cycles"
  note "'Sessions below the floor' is the headline of this study, so the"
  note "threshold must be fixed BEFORE the arms are compared. Only the baseline"
  note "runs here, so nothing about the pinned arms can influence it."

  GVPN_ARMS="$BASELINE" GVPN_CYCLES="$CAL_CYCLES" GVPN_STUDY="$STUDY" \
    "$KIT/bench/gvpn-bench.sh" --profile transfers || die "calibration run failed"

  CAL_RUN="$(ls -1dt "$GVPN_RUNS_DIR"/*/ 2>/dev/null | head -1)"; CAL_RUN="${CAL_RUN%/}"
  FLOOR="$(python3 "$KIT/bench/gvpn-analyze.py" "$CAL_RUN" --baseline "$BASELINE" --emit-floor)" \
    || die "could not compute a floor from $CAL_RUN"
  pass "$BASELINE p25 = $FLOOR Mbit/s"

  if grep -q '^GVPN_FLOOR_MBPS=' "$STUDY_FILE"; then
    sed -i "s|^GVPN_FLOOR_MBPS=.*|GVPN_FLOOR_MBPS=$FLOOR|" "$STUDY_FILE"
  else
    printf '\nGVPN_FLOOR_MBPS=%s\n' "$FLOOR" >> "$STUDY_FILE"
  fi
  note "written into $STUDY_FILE -- commit it, so the report cites a tracked value"
  GVPN_FLOOR_MBPS="$FLOOR"
fi

# ============================================================== STAGE E ====
stage "E  launch the FULL study"
printf '\n'
[ "$warns" -eq 0 ] && pass "all checks passed" || warn "$warns warning(s) above"

GVPN_STUDY="$STUDY" "$KIT/bench/gvpn-bench.sh" --dry-run | sed 's/^/  /'

if [ "$LAUNCH" != 1 ]; then
  cat <<EOF

  Checks and trial only -- the full study was NOT launched.
  Every arm ran through.

  To launch:
      sudo -E $0 --study $STUDY --launch -y
  or:
      make soak STUDY=$STUDY
EOF
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf '\n  launching in 10s -- ctrl-C to stop'
  for _ in $(seq 10); do printf '.'; sleep 1; done
  printf '\n'
fi

GVPN_STUDY="$STUDY" "$KIT/bench/gvpn-bench.sh" --detach

cat <<EOF

  Launched detached. It survives your SSH session closing.

      make status                 is it still going
      tail -f \$(readlink -f $GVPN_RUN_LOCK)/run.log
      make report                 when it finishes
      make publish STUDY=$STUDY

  preflight log: $LOG
EOF
