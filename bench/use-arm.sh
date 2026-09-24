#!/usr/bin/env bash
#
# use-arm.sh -- put one arm's configuration in place by hand, and optionally
#               connect and count how many distinct routes the planner draws from.
#
#   sudo ./bench/use-arm.sh pin-planner
#   sudo ./bench/use-arm.sh pin-planner --count      # connect, wait, count paths
#   sudo ./bench/use-arm.sh auto --count
#   ./bench/use-arm.sh --show                        # what is installed right now
#
# This is the same swap gvpn-bench.sh performs between arms, extracted so you can
# do it manually -- for the pin validation, or any time you want to poke at one
# configuration without starting a benchmark run.
#
# WHY ALL THREE PIECES MOVE TOGETHER
#
#   An arm is the client config, an optional manual hopr-lib config, and the
#   systemd drop-in that points the service at it. All three are rewritten on
#   every switch, INCLUDING being removed when an arm does not use them. Leaving
#   a planner-pinned hopr.yaml behind would silently pin the next arm too, and
#   the whole comparison would quietly become meaningless.
#
set -euo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
. "$KIT/lib/common.sh"

# Rendered instances in the state directory, not the repo's templates: a template
# has no config.toml and no addresses, so it cannot be installed.
ARMS_DIR="$GVPN_ARMS_DIR"
CONFIG_PATH="${GNOSISVPN_CONFIG_PATH:-/etc/gnosisvpn/config.toml}"
HOPR_YAML_DEST="${GVPN_HOPR_YAML_DEST:-/etc/gnosisvpn/hopr-arm.yaml}"
DROPIN="/etc/systemd/system/gnosisvpn.service.d/30-arm.conf"
LOG="${GVPN_SERVICE_LOG:-/var/log/gnosisvpn/gnosisvpn.log}"
DEST="${GVPN_DESTINATION:-UK}"
CTL="${GVPN_CTL:-gnosis_vpn-ctl}"
SETTLE="${GVPN_COUNT_SETTLE:-90}"
READY_TIMEOUT="${GVPN_READY_TIMEOUT:-120}"
CONNECT_TIMEOUT="${GVPN_CONNECT_TIMEOUT:-180}"

ARM=""; DO_COUNT=0; DO_SHOW=0

usage() {
  cat <<EOF
use-arm.sh -- install one arm's config; optionally connect and count paths

Usage: sudo $0 ARM [--count] [--dest ID]
       $0 --show

  ARM           directory name under $ARMS_DIR
  --count       after installing: connect, wait ${SETTLE}s, count distinct routes
  --dest ID     destination to connect to (default: $DEST, from gvpn.conf)
  --settle S    seconds to let traffic run before counting (default: $SETTLE)
  --show        print what is currently installed, then exit

Available arms (rendered instances in $ARMS_DIR):
$(ls "$ARMS_DIR" 2>/dev/null | sed 's/^/  /' || echo "  (none -- run setup/02-make-arms.sh)")
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --count)  DO_COUNT=1; shift ;;
    --show)   DO_SHOW=1; shift ;;
    --dest)   DEST="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  ARM="$1"; shift ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

show() {
  say "currently installed"
  echo "  config.toml destinations:"
  grep -E '^\[destinations\.|^path' "$CONFIG_PATH" 2>/dev/null | sed 's/^/    /' || true
  echo "  planner overrides:"
  sed -n '/\[connection.path_planner\]/,/^$/p' "$CONFIG_PATH" 2>/dev/null | sed 's/^/    /'
  echo "  drop-in: $([ -f "$DROPIN" ] && echo present || echo '<none>')"
  [ -f "$DROPIN" ] && sed 's/^/    /' "$DROPIN"
  echo "  service: $(systemctl is-active gnosisvpn 2>/dev/null || echo '?')"
}

[ "$DO_SHOW" = 1 ] && { show; exit 0; }
[ -n "$ARM" ] || { usage >&2; exit 2; }

ARM_DIR="$ARMS_DIR/$ARM"
[ -d "$ARM_DIR" ] || { echo "no such arm: $ARM_DIR" >&2; usage >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0 $ARM)" >&2; exit 1; }

say "installing arm: $ARM"
[ -r "$ARM_DIR/README" ] && sed 's/^/    /' "$ARM_DIR/README"

# Refuse before touching anything. An arm marked UNAVAILABLE is one whose
# mechanism has been checked against the source and does not exist; installing
# it would stop the client and the operator would be debugging their node
# rather than reading this.
if [ -f "$ARM_DIR/UNAVAILABLE" ]; then
  say "ARM '$ARM' CANNOT RUN"
  sed 's/^/    /' "$ARM_DIR/UNAVAILABLE"
  exit 2
fi

"$CTL" disconnect   >/dev/null 2>&1 || true
"$CTL" stop-client  >/dev/null 2>&1 || true
systemctl stop gnosisvpn
sleep 2

cp -a "$CONFIG_PATH" "$CONFIG_PATH.use-arm-backup" 2>/dev/null || true
cp "$ARM_DIR/config.toml" "$CONFIG_PATH"

mkdir -p "$(dirname "$DROPIN")"
# Legacy cleanup: older kit versions installed a hopr-lib YAML here and pointed
# the service at it with GNOSISVPN_HOPR_CONFIG_PATH. That lever never worked
# (docs/design.md section 3) and a leftover file would break every arm, so it
# is removed on every install, not only when switching to generated mode.
rm -f "$DROPIN" "$HOPR_YAML_DEST"
echo "    config.toml installed (generated hopr config)"

[ -f "$ARM_DIR/flags" ] && echo "    NOTE: this arm needs service flags: $(tr '\n' ' ' < "$ARM_DIR/flags")"
if [ -f "$ARM_DIR/PREREQUISITE" ]; then
  # Installing the config is not the same as the arm being ready. Say so here,
  # where someone is looking, rather than leaving it to a README nobody reopens.
  echo
  echo "    *** THIS ARM HAS AN UNAUTOMATED PREREQUISITE ***"
  sed 's/^/    /' "$ARM_DIR/PREREQUISITE"
  echo "    Confirm with --count before running a study with it."
fi

systemctl daemon-reload
systemctl start gnosisvpn
sleep 5

# Roll the node back to whatever it had before this arm touched it. Anything
# that leaves here must leave a WORKING node: a benchmark tool that bricks the
# thing it measures is worse than one that refuses to run.
rollback() {
  echo "    rolling back to the previous configuration"
  rm -f "$DROPIN" "$HOPR_YAML_DEST"
  [ -f "$CONFIG_PATH.use-arm-backup" ] && cp -a "$CONFIG_PATH.use-arm-backup" "$CONFIG_PATH"
  systemctl daemon-reload
  systemctl restart gnosisvpn
  sleep 5
  if systemctl is-active --quiet gnosisvpn; then
    echo "    service active again (generated config)"
  else
    echo "    ROLLBACK ALSO FAILED -- check: journalctl -u gnosisvpn -n 50"
  fi
}

if ! systemctl is-active --quiet gnosisvpn; then
  say "SERVICE DID NOT START"
  journalctl -u gnosisvpn -n 30 --no-pager | grep -iE 'error|panic|config|expected' || \
    journalctl -u gnosisvpn -n 30 --no-pager
  rollback
  exit 1
fi
echo "    service active"

# systemd being happy is NOT the same as the config being accepted. A rejected
# hopr-lib config does not fail the UNIT -- the worker starts, reads the file,
# and parks in Warmup reporting the parse error in its status string. Checking
# is-active alone passed here and left the node wedged for the five minutes the
# route count then spent polling. So ask the client itself.
say "verifying the client accepted the config"
cfg_err=""
for i in $(seq 1 12); do
  st="$(timeout 10 "$CTL" status 2>&1 || true)"
  case "$st" in
    *"config error"*|*"unknown field"*|*"Output error"*|*"missing field"*)
      cfg_err="$st"; break ;;
    Ready*|Connected*|Idle*)
      echo "    client reports: $(printf '%s' "$st" | head -1)"; cfg_err=""; break ;;
  esac
  sleep 5
done

if [ -n "$cfg_err" ]; then
  say "THE CLIENT REJECTED THIS ARM'S CONFIG"
  printf '%s\n' "$cfg_err" | sed 's/^/    /'
  cat <<'EOF'

    The unit is running; the worker is not. hopr-lib's config is
    deny_unknown_fields, so a key it does not know stops it dead rather than
    being ignored -- and "expected one of ..." in that message is the
    authoritative list of what this BUILD accepts, which may differ from any
    branch of the source.

EOF
  rollback
  exit 1
fi

[ "$DO_COUNT" = 1 ] || { show; exit 0; }

# ------------------------------------------------------------------- count --

say "counting distinct routes for arm '$ARM' (destination $DEST)"

if ! grep -q 'planner=debug' /etc/systemd/system/gnosisvpn.service.d/*.conf 2>/dev/null; then
  echo "    WARNING: planner DEBUG logging not found in the drop-ins."
  echo "    Without it there are no candidate-path lines to count."
  echo "    00-vm-setup.sh installs it as 10-bench-logging.conf."
fi

cat <<EOF
    This takes a few minutes and most of it is waiting. Expect:
      up to ${READY_TIMEOUT}s   node reaching Ready (channels, SURB warm-up)
      up to ${CONNECT_TIMEOUT}s   session establishing to $DEST
             ${SETTLE}s   traffic running so the planner actually draws paths
    Each line below is one poll, so silence means something is wrong.

EOF

# A wedged service socket makes ctl block forever. Cap every call: a status
# command that does not answer in 10s IS the diagnosis, not something to wait out.
ctl_status() { timeout 10 "$CTL" -o plain status 2>/dev/null; }

# Destinations are named in config.toml. Asking for one that is not there fails
# in a way that looks exactly like a slow connect, for three silent minutes.
if ! grep -qE "^\[destinations\.\"?${DEST}\"?\]" "$CONFIG_PATH" 2>/dev/null; then
  echo "    '$DEST' is not a destination in $CONFIG_PATH. Available:"
  grep -E '^\[destinations\.' "$CONFIG_PATH" 2>/dev/null | sed 's/^/      /'
  echo "    Set GVPN_DESTINATION in gvpn.conf, or pass --dest."
  exit 1
fi

: > "$LOG" 2>/dev/null || truncate -s 0 "$LOG"

# Start from a known state. A session left up by a previous --count means the
# node reports "Connected ..." and never "Ready", and the gate below would call
# a perfectly healthy node broken.
"$CTL" disconnect >/dev/null 2>&1 || true
sleep 2

"$CTL" start-client 60m >/dev/null 2>&1 || true
last=""
for i in $(seq 1 $((READY_TIMEOUT / 3))); do
  st="$(ctl_status | head -1)"
  [ "$st" != "$last" ] && { printf '    [%3ds] %s\n' "$((i * 3))" "${st:-<no answer from the service>}"; last="$st"; }
  # Connected also satisfies this gate: the node is past Ready, not short of it.
  case "$st" in Ready*|Connected*) break ;; esac
  sleep 3
done
case "$last" in
  Ready*|Connected*) ;;
  *) cat <<EOF

    NEVER REACHED Ready (last state: ${last:-<none>}).
    That is a node problem, not a benchmark one. Look at:
      gnosis_vpn-ctl info
      sudo journalctl -u gnosisvpn -n 50 --no-pager
    A node with no open channels, or one whose manual hopr config was rejected,
    sits here forever.
EOF
     exit 1 ;;
esac

"$CTL" connect "$DEST" >/dev/null 2>&1
last=""
for i in $(seq 1 $((CONNECT_TIMEOUT / 3))); do
  st="$(ctl_status | grep -E '^(Connected|Waiting|Connecting|Ready)' | head -1 || true)"
  [ "$st" != "$last" ] && { printf '    [%3ds] %s\n' "$((i * 3))" "${st:-<no answer>}"; last="$st"; }
  case "$st" in "Connected to $DEST"*) break ;; esac
  sleep 3
done
case "$last" in
  "Connected to $DEST"*) ;;
  *) echo; echo "    NEVER CONNECTED to $DEST (last state: ${last:-<none>})"
     echo "    sudo journalctl -u gnosisvpn -n 50 --no-pager"
     exit 1 ;;
esac

echo "    connected; running traffic for ${SETTLE}s"
# Something has to be moving for the planner to draw paths at all -- an idle
# tunnel produces almost no candidate lines.
TRAFFIC_URL="${GVPN_DL_URL:-https://speed.cloudflare.com/__down?bytes={bytes}}"
TRAFFIC_URL="${TRAFFIC_URL//\{bytes\}/200000000}"
( curl -s -o /dev/null --max-time "$SETTLE" "$TRAFFIC_URL" || true ) &
sleep "$SETTLE"
wait 2>/dev/null || true

# `|| true` on both, and on the listing below. Under `set -euo pipefail` a grep
# that matches nothing fails, pipefail propagates it, and set -e kills the script
# -- silently, at exactly the moment it has something important to report. "No
# candidate lines" is the single most useful thing this script can tell you, so
# it must not be the one case that cannot reach the screen.
LINES=$(grep -c 'candidate path' "$LOG" 2>/dev/null || true); LINES=${LINES:-0}
COUNT=$(grep -o 'path=[^ ]*' "$LOG" 2>/dev/null | sort -u | wc -l || true); COUNT=${COUNT:-0}

if [ "$LINES" -eq 0 ]; then
  say "NO RESULT: the log has no 'candidate path' lines at all"
  cat <<EOF
    $LOG

    This is NOT "one route". It means nothing was counted, because the planner
    is not logging at DEBUG. A count of 0 and a genuine pin of 1 look alike to
    anyone skimming, which is why this refuses to report a number.

    Check the logging drop-in, then re-run:
      grep -r planner /etc/systemd/system/gnosisvpn.service.d/
      sudo systemctl show gnosisvpn -p Environment | tr ' ' '\n' | grep RUST_LOG
    00-vm-setup.sh installs it as 10-bench-logging.conf.
EOF
  "$CTL" disconnect >/dev/null 2>&1 || true
  exit 1
fi

say "RESULT: arm '$ARM' drew from $COUNT distinct route(s)  ($LINES candidate lines)"
grep -o 'path=[^ ]*' "$LOG" 2>/dev/null | sort -u | head -20 | sed 's/^/    /' || true

cat <<EOF

    Expected: pin-planner = 1, auto = many (typically 5-20).
    Both many  -> the manual hopr config is not being read; check the drop-in at
                  /etc/systemd/system/gnosisvpn.service.d/30-arm.conf
    Both 1     -> the graph offers only one path; check the open channel count.
EOF

"$CTL" disconnect >/dev/null 2>&1 || true
