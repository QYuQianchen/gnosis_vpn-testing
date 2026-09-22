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
  echo "  manual hopr config: $([ -f "$HOPR_YAML_DEST" ] && echo "$HOPR_YAML_DEST" || echo '<none -- generated mode>')"
  [ -f "$HOPR_YAML_DEST" ] && sed -n '/path_planner/,$p' "$HOPR_YAML_DEST" | sed 's/^/    /'
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

"$CTL" disconnect   >/dev/null 2>&1 || true
"$CTL" stop-client  >/dev/null 2>&1 || true
systemctl stop gnosisvpn
sleep 2

cp -a "$CONFIG_PATH" "$CONFIG_PATH.use-arm-backup" 2>/dev/null || true
cp "$ARM_DIR/config.toml" "$CONFIG_PATH"

mkdir -p "$(dirname "$DROPIN")"
if [ -f "$ARM_DIR/hopr.yaml" ] || [ -f "$ARM_DIR/env" ]; then
  { echo "[Service]"
    [ -f "$ARM_DIR/hopr.yaml" ] && cp "$ARM_DIR/hopr.yaml" "$HOPR_YAML_DEST"
    [ -f "$ARM_DIR/env" ] && while IFS= read -r line; do
      [ -n "$line" ] && printf 'Environment=%s\n' "$line"
    done < "$ARM_DIR/env"
  } > "$DROPIN"
  echo "    manual hopr config + drop-in installed"
else
  # Removal matters as much as installation: a leftover pinned hopr.yaml would
  # silently pin the NEXT arm too.
  rm -f "$DROPIN" "$HOPR_YAML_DEST"
  echo "    generated hopr config (drop-in and hopr.yaml removed)"
fi

[ -f "$ARM_DIR/flags" ] && echo "    NOTE: this arm needs service flags: $(tr '\n' ' ' < "$ARM_DIR/flags")"

systemctl daemon-reload
systemctl start gnosisvpn
sleep 5

if ! systemctl is-active --quiet gnosisvpn; then
  say "SERVICE DID NOT START"
  # Nearly always a rejected manual hopr-lib config: HoprLibConfig is
  # deny_unknown_fields, so one wrong key stops the service rather than warning.
  journalctl -u gnosisvpn -n 30 --no-pager | grep -iE 'error|panic|config|expected' || \
    journalctl -u gnosisvpn -n 30 --no-pager
  exit 1
fi
echo "    service active"

[ "$DO_COUNT" = 1 ] || { show; exit 0; }

# ------------------------------------------------------------------- count --

say "counting distinct routes for arm '$ARM' (destination $DEST)"

if ! grep -q 'planner=debug' /etc/systemd/system/gnosisvpn.service.d/*.conf 2>/dev/null; then
  echo "    WARNING: planner DEBUG logging not found in the drop-ins."
  echo "    Without it there are no candidate-path lines to count."
  echo "    00-vm-setup.sh installs it as 10-bench-logging.conf."
fi

: > "$LOG" 2>/dev/null || truncate -s 0 "$LOG"

"$CTL" start-client 60m >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
  "$CTL" -o plain status 2>/dev/null | head -1 | grep -q '^Ready' && break
  sleep 3
done

"$CTL" connect "$DEST" >/dev/null 2>&1
for _ in $(seq 1 60); do
  "$CTL" -o plain status 2>/dev/null | grep -q "^Connected to $DEST " && break
  sleep 3
done
"$CTL" -o plain status 2>/dev/null | grep -E '^(Connected|Waiting|Connecting)' || {
  echo "    never connected to $DEST"; exit 1; }

echo "    connected; letting it run ${SETTLE}s"
# Something has to be moving for the planner to draw paths at all -- an idle
# tunnel produces almost no candidate lines.
( curl -s -o /dev/null --max-time "$SETTLE" \
    "https://speed.cloudflare.com/__down?bytes=200000000" || true ) &
sleep "$SETTLE"
wait 2>/dev/null || true

COUNT=$(grep -o 'path=[^ ]*' "$LOG" 2>/dev/null | sort -u | wc -l)
say "RESULT: arm '$ARM' drew from $COUNT distinct route(s)"
grep -o 'path=[^ ]*' "$LOG" 2>/dev/null | sort -u | head -20 | sed 's/^/    /'

cat <<EOF

    Expected: pin-planner = 1, auto = many (typically 5-20).
    Both many  -> the manual hopr config is not being read; check the drop-in.
    Both 1     -> either the graph offers only one path (check channel count),
                  or DEBUG logging is off and you are counting nothing.
EOF

"$CTL" disconnect >/dev/null 2>&1 || true
