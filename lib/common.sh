# lib/common.sh -- sourced by every script: locations, config loading, and the
# one correct way to install an arm's config and (re)start the service.
#
# State lives OUTSIDE the repo ($GVPN_STATE, default ~/gvpn-state): the VM
# checkout is a push-to-checkout target, so anything inside it is one deploy
# away from gone. Under sudo $HOME is /root, so the state dir is resolved from
# the INVOKING user -- otherwise sudo and non-sudo runs would use two different
# state directories without saying so.

gvpn_home() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    echo "${HOME:-/root}"
  fi
}

GVPN_KIT="${GVPN_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GVPN_STATE="${GVPN_STATE:-$(gvpn_home)/gvpn-state}"
GVPN_RUNS_DIR="${GVPN_RUNS_DIR:-$GVPN_STATE/runs}"
GVPN_ARMS_DIR="${GVPN_ARMS_DIR:-$GVPN_STATE/arms}"
GVPN_BACKUP_DIR="${GVPN_BACKUP_DIR:-$GVPN_STATE/identity-backup}"
GVPN_RUN_LOCK="${GVPN_RUN_LOCK:-$GVPN_STATE/run.lock}"      # blocks deploys mid-run
GVPN_ARM_TEMPLATES="${GVPN_ARM_TEMPLATES:-$GVPN_KIT/arms}"

# The client's config. config.toml is a SYMLINK the installer uses to select a
# network (-> config-jura-prod.toml). Never write through it: `cp x config.toml`
# overwrites the packaged network config, and `cp -a config.toml bak` backs up
# the link, not the file. Arms get their own file and the link is re-pointed.
GVPN_CONFIG_DIR="${GVPN_CONFIG_DIR:-/etc/gnosisvpn}"
GVPN_CONFIG_PATH="${GNOSISVPN_CONFIG_PATH:-$GVPN_CONFIG_DIR/config.toml}"
GVPN_ARM_CONFIG="$GVPN_CONFIG_DIR/config-gvpn-arm.toml"
GVPN_CONFIG_ORIG="$GVPN_CONFIG_DIR/.gvpn-config-original"  # original link target
GVPN_SERVICE_LOG="${GVPN_SERVICE_LOG:-/var/log/gnosisvpn/gnosisvpn.log}"

gvpn_state_init() {
  mkdir -p "$GVPN_RUNS_DIR" "$GVPN_ARMS_DIR" "$GVPN_BACKUP_DIR"
  chmod 700 "$GVPN_BACKUP_DIR" 2>/dev/null || true
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    chown -R "$SUDO_USER" "$GVPN_STATE" 2>/dev/null || true
  fi
}

# gvpn.conf holds defaults; a study file (studies/<name>.conf) overrides them.
gvpn_load_conf() {
  local conf="${GVPN_CONFIG:-$GVPN_KIT/gvpn.conf}"
  [ -r "$conf" ] && { set -a; . "$conf"; set +a; GVPN_CONF_LOADED="$conf"; }
  if [ -n "${GVPN_STUDY:-}" ]; then
    local s
    for s in "$GVPN_STUDY" "$GVPN_KIT/studies/$GVPN_STUDY" "$GVPN_KIT/studies/$GVPN_STUDY.conf"; do
      [ -r "$s" ] && break
    done
    [ -r "$s" ] || { echo "study not found: $GVPN_STUDY" >&2; return 1; }
    set -a; . "$s"; set +a
    GVPN_STUDY_LOADED="$s"; GVPN_STUDY_NAME="$(basename "$s" .conf)"
  fi
  return 0
}

# ---------------------------------------------------------- arm config I/O --

gvpn_config_check() {  # gvpn_config_check FILE -- non-zero if it would not load
  python3 "$GVPN_KIT/lib/tomlmerge.py" check "$1" >/dev/null
}

# Record, once, what config.toml pointed at before this kit touched it.
gvpn_remember_original() {
  [ -s "$GVPN_CONFIG_ORIG" ] && return 0
  local t; t="$(readlink -f "$GVPN_CONFIG_PATH")"
  [ "$t" = "$GVPN_ARM_CONFIG" ] && return 0      # already an arm; nothing to record
  printf '%s\n' "$t" > "$GVPN_CONFIG_ORIG"
}

gvpn_install_arm() {  # gvpn_install_arm SRC_CONFIG
  gvpn_config_check "$1" || { echo "refusing to install $1: it does not parse" >&2; return 1; }
  gvpn_remember_original
  install -m 0644 "$1" "$GVPN_ARM_CONFIG"
  chown --reference="$(cat "$GVPN_CONFIG_ORIG")" "$GVPN_ARM_CONFIG" 2>/dev/null || true
  ln -sfn "$GVPN_ARM_CONFIG" "$GVPN_CONFIG_PATH"
}

gvpn_restore_original() {
  local o; o="$(cat "$GVPN_CONFIG_ORIG" 2>/dev/null)"
  [ -n "$o" ] && [ -e "$o" ] || return 1
  ln -sfn "$o" "$GVPN_CONFIG_PATH"
}

# (Re)start the service. reset-failed first: after five quick failures systemd
# refuses every further start with "start request repeated too quickly".
# "Healthy" means active AND not auto-restarted since: with RestartSec=5s, a
# crash-looping unit is briefly "active" after every restart.
gvpn_service_restart() {
  systemctl daemon-reload
  systemctl reset-failed gnosisvpn 2>/dev/null || true
  systemctl restart gnosisvpn
  local n0; n0="$(systemctl show gnosisvpn -p NRestarts --value)"
  sleep 8
  [ "$(systemctl show gnosisvpn -p NRestarts --value)" = "$n0" ] &&
    systemctl is-active --quiet gnosisvpn
}

# Why the service is down, in one line. gnosis_vpn-root maps EVERY config
# failure -- unreadable, unparseable, unknown key -- to exit 66 (EX_NOINPUT),
# and logs the reason to its log file, not to journald.
gvpn_service_why() {
  local code; code="$(systemctl show gnosisvpn -p ExecMainStatus --value 2>/dev/null)"
  case "$code" in
    66) echo "exit 66: the config failed to read or PARSE -- a bad or duplicate key counts" ;;
    67) echo "exit 67: the worker user could not be determined" ;;
    74) echo "exit 74: I/O error -- config path, socket, runtime dir or daemon lock" ;;
    75) echo "exit 75: another instance already holds the daemon lock" ;;
    *)  echo "exit ${code:-?}" ;;
  esac
  grep -a 'unable to read initial configuration' "$GVPN_SERVICE_LOG" 2>/dev/null | tail -1
}

gvpn_load_conf || true
