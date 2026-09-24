#!/usr/bin/env bash
#
# restore-config.sh -- undo the damage from writing through the config symlink.
#
#   sudo ./tools/restore-config.sh          show what is wrong
#   sudo ./tools/restore-config.sh --apply  put the packaged config back
#
# THE BUG THIS CLEANS UP
#
#   /etc/gnosisvpn/config.toml is a SYMLINK selecting a network config
#   (-> config-jura-prod.toml). Earlier versions of use-arm.sh and gvpn-bench.sh
#   ran `cp ARM config.toml`, which follows the link and overwrites the PACKAGED
#   network config -- the only copy on the box. Their `cp -a` "backup" copied
#   the link rather than its contents, so rollback restored nothing.
#
#   Symptom: config-jura-prod.toml has a recent mtime and contains arm settings,
#   and config.toml.use-arm-backup / config.toml.backup.* are all symlinks to it.
#
set -uo pipefail

CONFIG_DIR="${GNOSISVPN_CONFIG_DIR:-/etc/gnosisvpn}"
CONFIG_PATH="$CONFIG_DIR/config.toml"
NET="${GVPN_NETWORK:-jura-prod}"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
case "${1:-}" in -h|--help) sed -n '2,20p' "$0"; exit 0 ;; esac

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "current state"
ls -la "$CONFIG_DIR" | sed 's/^/    /'

TARGET="$(readlink -f "$CONFIG_PATH" 2>/dev/null || echo "$CONFIG_PATH")"
echo
echo "    config.toml resolves to: $TARGET"
if grep -q 'connection.path_planner' "$TARGET" 2>/dev/null; then
  echo "    >>> it contains [connection.path_planner] -- an ARM config, written"
  echo "        over the packaged one."
else
  echo "    no arm planner section in it."
fi

# Say plainly which "backups" cannot restore anything, rather than letting
# someone restore from one and believe they are fixed.
echo
for b in "$CONFIG_DIR"/config.toml.*backup*; do
  [ -e "$b" ] || continue
  if [ -L "$b" ]; then
    echo "    USELESS (a link, not a copy): $b -> $(readlink "$b")"
  else
    echo "    real copy: $b"
  fi
done

if [ "$APPLY" = 0 ]; then
  echo
  echo "Nothing changed. To repair, re-run with --apply. It will:"
  echo "  1. reinstall the packaged config from apt (the only pristine source)"
  echo "  2. point config.toml back at config-$NET.toml"
  echo "  3. delete the symlink 'backups', which cannot restore anything"
  echo
  echo "    sudo $0 --apply"
  exit 0
fi

say "reinstalling the packaged configs"
PKG="$(dpkg -S "$CONFIG_DIR/config-$NET.toml" 2>/dev/null | cut -d: -f1 | head -1)"
if [ -n "$PKG" ]; then
  echo "    owning package: $PKG"
  apt-get install -y -qq --reinstall -o Dpkg::Options::="--force-confmiss" "$PKG" \
    || { echo "    reinstall failed -- run setup/00-vm-setup.sh instead" >&2; exit 1; }
else
  echo "    no package owns $CONFIG_DIR/config-$NET.toml" >&2
  echo "    re-run: sudo ./setup/00-vm-setup.sh --network $NET --allow-insecure" >&2
  exit 1
fi

say "pointing config.toml at the network config"
ln -sfn "$CONFIG_DIR/config-$NET.toml" "$CONFIG_PATH"
ls -la "$CONFIG_PATH" | sed 's/^/    /'

say "removing the symlink backups"
for b in "$CONFIG_DIR"/config.toml.*backup*; do
  [ -L "$b" ] || continue
  rm -f "$b" && echo "    removed $b"
done
rm -f "$CONFIG_DIR/.gvpn-config-original"

say "done"
echo "    sudo systemctl start gnosisvpn && systemctl is-active gnosisvpn"
