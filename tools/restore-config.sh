#!/usr/bin/env bash
#
# restore-config.sh -- put the packaged network config back, and the service up.
#
#   sudo ./tools/restore-config.sh          inspect; changes nothing
#   sudo ./tools/restore-config.sh --apply  repair
#
# Repairs a node damaged by kits before the config.toml fix, which wrote arm
# configs THROUGH the config.toml symlink into the packaged network config
# (config-<net>.toml). That file then declared [connection.path_planner] twice,
# the client rejected it with exit 66, and the "backups" those kits made were
# symlinks to the same damaged file.
#
# --apply moves the damaged file aside (kept, for evidence), reinstalls it from
# the package, re-points config.toml, and restarts the service. The node
# identity in /var/lib/gnosisvpn is never touched.
set -uo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

NET="${GVPN_NETWORK:-jura-prod}"
NETCONF="$GVPN_CONFIG_DIR/config-$NET.toml"
APPLY=0
case "${1:-}" in
  --apply)   APPLY=1 ;;
  -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        ;;
  *)         echo "unknown option: $1" >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

PKG="$(dpkg -S "$NETCONF" 2>/dev/null | cut -d: -f1 | head -1)"
modified() { [ -n "$PKG" ] && dpkg --verify "$PKG" 2>/dev/null | grep -q " $NETCONF\$"; }

say "inspecting"
echo "    network:     $NET"
echo "    config.toml: -> $(readlink -f "$GVPN_CONFIG_PATH" 2>/dev/null || echo '<missing>')"
echo "    package:     ${PKG:-<no package owns $NETCONF>}"
damaged=0
if [ ! -f "$NETCONF" ]; then
  echo "    $NETCONF is MISSING"; damaged=1
elif ! gvpn_config_check "$NETCONF" 2>/dev/null; then
  echo "    $NETCONF does NOT PARSE:"
  python3 "$GVPN_KIT/lib/tomlmerge.py" check "$NETCONF" 2>&1 | sed 's/^/      /'
  damaged=1
elif modified; then
  echo "    $NETCONF parses, but differs from the package (dpkg --verify)"; damaged=1
else
  echo "    $NETCONF is pristine"
fi
for b in "$GVPN_CONFIG_DIR"/config.toml.*backup*; do
  [ -L "$b" ] && echo "    useless backup (a symlink, not a copy): $(basename "$b")"
done
echo "    service:     $(systemctl is-active gnosisvpn)  $(gvpn_service_why | head -1)"

if [ "$APPLY" = 0 ]; then
  echo
  [ "$damaged" = 1 ] && echo "Repair with:  sudo $0 --apply" || echo "Nothing to repair in the config."
  exit 0
fi

# ------------------------------------------------------------------ repair --
systemctl stop gnosisvpn 2>/dev/null || true

if [ "$damaged" = 1 ]; then
  [ -n "$PKG" ] || { echo "no package owns $NETCONF -- reinstall with the upstream installer:" >&2
                     echo "  curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --network=$NET" >&2
                     exit 1; }
  say "reinstalling $NETCONF from $PKG"
  aside=""
  if [ -f "$NETCONF" ]; then
    aside="$NETCONF.damaged-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$NETCONF" "$aside" && echo "    damaged copy kept as $(basename "$aside")"
  fi
  # --force-confmiss restores a conffile only when it is MISSING -- dpkg keeps
  # a modified one on purpose -- which is why it was moved aside first.
  if ! apt-get install -y -qq --reinstall --allow-change-held-packages \
         -o Dpkg::Options::=--force-confmiss "$PKG"; then
    [ -n "$aside" ] && mv "$aside" "$NETCONF"          # no worse than before
    echo "    reinstall failed (is this exact version still in the repo?). Use the installer:" >&2
    echo "      curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --network=$NET" >&2
    exit 1
  fi
  gvpn_config_check "$NETCONF" || { echo "    reinstalled file still does not parse" >&2; exit 1; }
  modified && echo "    WARNING: still differs from the package" || echo "    pristine again"
fi

say "pointing config.toml at the network config"
ln -sfn "$NETCONF" "$GVPN_CONFIG_PATH"
rm -f "$GVPN_CONFIG_ORIG" "$GVPN_ARM_CONFIG"
for b in "$GVPN_CONFIG_DIR"/config.toml.*backup*; do
  [ -L "$b" ] && rm -f "$b" && echo "    removed symlink backup $(basename "$b")"
done

say "starting the service"
if gvpn_service_restart; then
  echo "    active. Next: sudo -E ./setup/02-make-arms.sh"
else
  echo "    still not starting: $(gvpn_service_why | head -1)" >&2
  echo "    sudo ./tools/diagnose.sh" >&2
  exit 1
fi
