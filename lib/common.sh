# lib/common.sh -- sourced by every script in the kit.
#
#   . "$(dirname "$0")/../lib/common.sh"
#
# Three jobs, all of which used to be repeated (and drift) in each script:
#
#   1. Find the kit root, so a script works from any working directory.
#   2. Find the STATE directory -- the one place that holds everything the repo
#      must never contain: raw run output, generated arms carrying safe and
#      module addresses, faucet codes, identity backups.
#   3. Load configuration: gvpn.conf, then a study file on top of it.
#
# WHY STATE LIVES OUTSIDE THE REPO
#
#   The VM's checkout is a git push target with a push-to-checkout hook. A push
#   rewrites the worktree. Anything valuable inside it -- a 40-hour soak, the
#   node identity, the faucet codes -- is one deploy or one `git clean -fdx`
#   away from gone. Keeping state outside means the repo can be replaced wholesale
#   at any moment and nothing irreplaceable moves.
#
# THE sudo TRAP
#
#   Most of this kit runs under sudo, where $HOME is /root. Defaulting the state
#   directory to "$HOME/gvpn-state" would put the runs in /root for a sudo
#   invocation and in the deploy user's home otherwise -- two state directories,
#   silently, and a soak whose results the analyser cannot find. gvpn_home()
#   resolves the INVOKING user's home instead, so both paths agree.

# ---------------------------------------------------------------- locations --

gvpn_home() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    echo "${HOME:-/root}"
  fi
}

# Kit root: the directory containing lib/, bench/, setup/.
GVPN_KIT="${GVPN_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Everything the repo must not contain.
GVPN_STATE="${GVPN_STATE:-$(gvpn_home)/gvpn-state}"

GVPN_RUNS_DIR="${GVPN_RUNS_DIR:-$GVPN_STATE/runs}"
GVPN_ARMS_DIR="${GVPN_ARMS_DIR:-$GVPN_STATE/arms}"
GVPN_SECRETS_DIR="${GVPN_SECRETS_DIR:-$GVPN_STATE/secrets}"
GVPN_BACKUP_DIR="${GVPN_BACKUP_DIR:-$GVPN_STATE/identity-backup}"

# Symlink to the run currently in progress. The deploy hook refuses to replace
# the worktree while it exists, because push-to-checkout rewrites script files in
# place and bash reads a script incrementally as it executes -- a push mid-soak
# can corrupt the running bench, or quietly swap the analysis under a study.
GVPN_RUN_LOCK="${GVPN_RUN_LOCK:-$GVPN_STATE/run.lock}"

# Arm TEMPLATES, tracked in the repo. Rendered into $GVPN_ARMS_DIR by
# setup/02-make-arms.sh, which is where the addresses get substituted in.
GVPN_ARM_TEMPLATES="${GVPN_ARM_TEMPLATES:-$GVPN_KIT/arms}"

gvpn_state_init() {
  mkdir -p "$GVPN_RUNS_DIR" "$GVPN_ARMS_DIR" "$GVPN_SECRETS_DIR" "$GVPN_BACKUP_DIR"
  chmod 700 "$GVPN_SECRETS_DIR" "$GVPN_BACKUP_DIR" 2>/dev/null || true
  # Created under sudo, used without it: hand it back to the invoking user or
  # every later non-root read fails in a way that looks like a missing file.
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    chown -R "$SUDO_USER" "$GVPN_STATE" 2>/dev/null || true
  fi
}

# ------------------------------------------------------------ configuration --

# gvpn.conf holds the defaults; a study file overrides them for one experiment.
# Keeping the study in its own tracked file is what makes a result reproducible:
# "which settings produced this?" is answered by a filename in the report, not by
# whatever the shared config happened to say that week.
gvpn_load_conf() {
  local conf="${GVPN_CONFIG:-$GVPN_KIT/gvpn.conf}"
  GVPN_CONF_LOADED=""
  if [ -r "$conf" ]; then
    set -a; . "$conf"; set +a
    GVPN_CONF_LOADED="$conf"
  fi
  if [ -n "${GVPN_STUDY:-}" ]; then
    local study="$GVPN_STUDY"
    [ -r "$study" ] || study="$GVPN_KIT/studies/$GVPN_STUDY"
    [ -r "$study" ] || study="$GVPN_KIT/studies/$GVPN_STUDY.conf"
    if [ -r "$study" ]; then
      set -a; . "$study"; set +a
      GVPN_STUDY_LOADED="$study"
      GVPN_STUDY_NAME="$(basename "$study" .conf)"
    else
      echo "study not found: $GVPN_STUDY (looked in $GVPN_KIT/studies/)" >&2
      return 1
    fi
  fi
  # Re-resolve: gvpn.conf or the study may have set GVPN_STATE.
  GVPN_RUNS_DIR="${GVPN_RUNS_DIR:-$GVPN_STATE/runs}"
  GVPN_ARMS_DIR="${GVPN_ARMS_DIR:-$GVPN_STATE/arms}"
  return 0
}

gvpn_conf_summary() {
  printf 'kit:    %s\n' "$GVPN_KIT"
  printf 'state:  %s\n' "$GVPN_STATE"
  printf 'config: %s\n' "${GVPN_CONF_LOADED:-<none>}"
  [ -n "${GVPN_STUDY_LOADED:-}" ] && printf 'study:  %s\n' "$GVPN_STUDY_LOADED"
  return 0
}

gvpn_load_conf || true
