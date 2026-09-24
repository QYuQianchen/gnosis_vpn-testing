#!/usr/bin/env bash
#
# diagnose.sh -- everything needed to explain why the service will not start,
# in one paste.
#
#   sudo ./tools/diagnose.sh
#
# This exists because diagnosing a dead daemon took six round trips of "run this
# one command": the unit, the env files, the config, the drop-ins, the identity
# and the binary's own output are each useless alone. It reads only; it changes
# nothing, and it redacts addresses and keys so the output is safe to paste.

set -uo pipefail

CONFIG_DIR="${GNOSISVPN_CONFIG_DIR:-/etc/gnosisvpn}"
CONFIG_PATH="${GNOSISVPN_CONFIG_PATH:-$CONFIG_DIR/config.toml}"
STATE_DIR="${GNOSISVPN_STATE_DIR:-/var/lib/gnosisvpn}"
DROPIN_DIR=/etc/systemd/system/gnosisvpn.service.d

h() { printf '\n========== %s ==========\n' "$*"; }

# Addresses and peer IDs are not secrets, but an identity file's contents are,
# and a config can carry both. Redact by shape rather than by key name.
redact() {
  sed -E -e 's/0x[0-9a-fA-F]{40}/0x<ADDR-40>/g' \
         -e 's/0x[0-9a-fA-F]{64}/0x<KEY-64>/g' \
         -e 's/\b1[1-9A-HJ-NP-Za-km-z]{45,}\b/<PEERID>/g' \
         -e 's/\b12D3Koo[1-9A-HJ-NP-Za-km-z]+/<PEERID>/g'
}

h "exit status"
code="$(systemctl show gnosisvpn -p ExecMainStatus --value 2>/dev/null)"
echo "ExecMainStatus: ${code:-<unknown>}"
case "$code" in
  0)  echo "  exited cleanly" ;;
  64) echo "  EX_USAGE     bad command line -- check ExecStart and the flags drop-in" ;;
  66) echo "  EX_NOINPUT   a file could not be OPENED. The config was never read," ;
      echo "               so this is NOT a bad config key." ;;
  69) echo "  EX_UNAVAILABLE  a dependency is unreachable" ;;
  70) echo "  EX_SOFTWARE  internal error" ;;
  77) echo "  EX_NOPERM    permission denied" ;;
  78) echo "  EX_CONFIG    the config WAS read and rejected -- a bad key" ;;
esac
systemctl is-active gnosisvpn || true

h "unit and drop-ins"
systemctl cat gnosisvpn 2>&1 | redact
echo
if [ -d "$DROPIN_DIR" ]; then
  ls -la "$DROPIN_DIR"
  n=$(find "$DROPIN_DIR" -name '*.conf' 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || echo ">>> drop-in directory exists but is EMPTY: 00-vm-setup.sh has not run, or its files were removed"
else
  echo ">>> $DROPIN_DIR does not exist: 00-vm-setup.sh has never run on this node"
fi
echo ">>> planner DEBUG logging: $(grep -rl 'planner=debug' "$DROPIN_DIR" 2>/dev/null || echo 'ABSENT -- --count cannot work')"
echo ">>> --allow-insecure:      $(systemctl show gnosisvpn -p ExecStart 2>/dev/null | grep -o -- --allow-insecure || echo 'absent -- zero-hop cannot run')"

h "environment files"
for f in "$CONFIG_DIR/gnosisvpn.env" "$CONFIG_DIR/gnosisvpn-dynamic.env"; do
  echo "--- $f"
  if [ -f "$f" ]; then redact < "$f"; else echo "    MISSING"; fi
done

h "config directory"
ls -la "$CONFIG_DIR" 2>&1
echo
echo "--- $CONFIG_PATH"
if [ -f "$CONFIG_PATH" ]; then
  echo "    $(stat -c '%A %U:%G %s bytes' "$CONFIG_PATH")"
  [ -s "$CONFIG_PATH" ] || echo "    >>> EMPTY"
  echo "    tables:"
  grep -nE '^\[' "$CONFIG_PATH" | sed 's/^/      /' | redact
else
  echo "    MISSING -- this alone explains EX_NOINPUT"
fi

h "every absolute path the config and env files name"
{ [ -f "$CONFIG_PATH" ] && cat "$CONFIG_PATH"
  cat "$CONFIG_DIR"/*.env 2>/dev/null; } 2>/dev/null \
  | grep -oE '/[A-Za-z0-9_./-]{4,}' | sort -u | while read -r f; do
      case "$f" in */) continue ;; esac
      [ -e "$f" ] && printf '  ok       %s\n' "$f" || printf '  MISSING  %s\n' "$f"
    done

h "state and identity"
ls -la "$STATE_DIR" 2>&1
echo
echo "--- $STATE_DIR/.config"
if [ -d "$STATE_DIR/.config" ]; then
  ls -la "$STATE_DIR/.config" 2>&1 | redact
  [ -n "$(ls -A "$STATE_DIR/.config" 2>/dev/null)" ] \
    || echo "    >>> EMPTY -- the node has never onboarded"
else
  echo "    MISSING -- the node has never onboarded"
fi

h "what the binary itself printed (unfiltered)"
journalctl -u gnosisvpn -n 25 --no-pager -o cat 2>&1 | redact
echo
echo "--- with systemd's own lines, for the restart pattern"
journalctl -u gnosisvpn -n 12 --no-pager 2>&1 | redact

h "service log file"
if [ -s /var/log/gnosisvpn/gnosisvpn.log ]; then
  tail -20 /var/log/gnosisvpn/gnosisvpn.log | redact
else
  echo "/var/log/gnosisvpn/gnosisvpn.log is absent or empty"
fi

h "does it start by hand"
echo "Run this yourself if the above is inconclusive -- it prints what systemd swallows:"
echo "  sudo -u root env \$(grep -v '^#' $CONFIG_DIR/gnosisvpn.env | xargs) /usr/bin/gnosis_vpn-root"

h "packages"
dpkg-query -W -f='${Package} ${Version}\n' 'gnosis*' 2>/dev/null || true

echo
echo "End of report. Nothing was changed."
