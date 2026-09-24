#!/usr/bin/env bash
#
# 05-set-version.sh -- switch or pin the Gnosis VPN build, from gvpn.conf.
#
#   ./05-set-version.sh --show                 what is installed, and what is available
#   ./05-set-version.sh --list                 every version apt can see
#   sudo ./05-set-version.sh --apply           install what gvpn.conf asks for
#   sudo ./05-set-version.sh --channel snapshot --apply
#   sudo ./05-set-version.sh --version 0.97.1 --apply
#
# WHY THIS IS A SCRIPT AND NOT A COMMAND YOU RETYPE
#
#   Three ways to get the build wrong, all of which have bitten people:
#
#   1. Re-running the installer WITHOUT --channel selects stable. On a snapshot
#      install that is a silent DOWNGRADE, and the installer performs it happily
#      because a plain `apt upgrade` would never move backwards on its own.
#   2. 00-vm-setup.sh runs `apt-mark hold gnosisvpn` so an unattended upgrade
#      cannot swap the binary mid-soak. Any upgrade therefore has to unhold
#      first, and re-hold afterwards -- forgetting the re-hold reopens the hole.
#   3. A channel switch can move the client across release lines, and the
#      networks available differ per line. If the configured network is not in
#      the target channel, the installer silently re-points the config at that
#      channel's default network -- so the exit set can change underneath you.
#
#   And the reason it matters for the study: every arm has to run on the same
#   binary. A mid-run upgrade splits the dataset in a way interleaving cannot
#   repair, because the arm and the version become confounded. Pin once, record
#   it, and leave it alone until the run is finished.
#
set -euo pipefail

CONFIG_FILE="${GVPN_CONFIG:-$(cd "$(dirname "$0")/.." && pwd)/gvpn.conf}"
[ -r "$CONFIG_FILE" ] && { set -a; . "$CONFIG_FILE"; set +a; }

CHANNEL="${GVPN_CHANNEL:-stable}"
NETWORK="${GVPN_NETWORK:-jura-prod}"
PIN_VERSION="${GVPN_PIN_VERSION:-}"
BUILD_FILE="$GVPN_STATE/BUILD.txt"
# Legacy: older kits wrote this into the worktree, where a sudo run left it
# root-owned and blocked deploys. Read the old one if the new one is absent.
LEGACY_BUILD_FILE="$(cd "$(dirname "$0")/.." && pwd)/BUILD.txt"
[ -r "$BUILD_FILE" ] || [ ! -r "$LEGACY_BUILD_FILE" ] || BUILD_FILE="$LEGACY_BUILD_FILE"
ACTION=show

usage() {
  cat <<EOF
05-set-version.sh -- switch or pin the Gnosis VPN build

Usage: $0 [--show | --list | --apply] [--channel NAME] [--version VER]

  --show          installed version, configured channel, apt candidate  [default]
  --list          every version apt can see in the configured channel
  --apply         make the installed build match the settings below (needs root)
  --channel NAME  stable | snapshot | experimental   (overrides gvpn.conf)
  --version VER   exact apt version to hold at, e.g. 0.96.0; empty = channel newest
  --config PATH   config file (default: ../gvpn.conf)

Reads from: $CONFIG_FILE
  channel=$CHANNEL  network=$NETWORK  pin=${PIN_VERSION:-<newest in channel>}

Networks per channel -- a switch that strands the configured network silently
re-points the config at the channel default:
  stable, snapshot   jura-prod, jura-dev
  experimental       piz-palu-dev
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --show)    ACTION=show; shift ;;
    --list)    ACTION=list; shift ;;
    --apply)   ACTION=apply; shift ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --version) PIN_VERSION="$2"; shift 2 ;;
    --config)  shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

sources_channel() {
  sed -n 's/.*gnosisvpn[^ ]*\/\([a-z]*\).*/\1/p' \
      /etc/apt/sources.list.d/gnosisvpn.sources 2>/dev/null | head -1
}

show() {
  say "installed"
  command -v gnosis_vpn-ctl >/dev/null 2>&1 && gnosis_vpn-ctl -V || echo "    not installed"
  dpkg-query -W -f='    package version: ${Version}\n' gnosisvpn 2>/dev/null || true
  apt-mark showhold 2>/dev/null | grep -q '^gnosisvpn$' \
    && echo "    apt hold: YES (an upgrade needs --apply, which unholds and re-holds)" \
    || echo "    apt hold: no  -- an unattended upgrade could swap this mid-run"

  say "configured"
  echo "    sources channel: $(sources_channel || echo '?')"
  echo "    gvpn.conf wants: channel=$CHANNEL network=$NETWORK pin=${PIN_VERSION:-<newest>}"
  [ -r "$BUILD_FILE" ] && { echo; echo "    BUILD.txt:"; sed 's/^/      /' "$BUILD_FILE"; }

  say "available"
  apt policy gnosisvpn 2>/dev/null | sed 's/^/    /' || echo "    run: sudo apt-get update"
}

case "$ACTION" in
  show) show; exit 0 ;;
  list)
    say "versions apt can see (channel: $(sources_channel || echo '?'))"
    apt-cache madison gnosisvpn 2>/dev/null | sed 's/^/    /' \
      || echo "    nothing -- run: sudo apt-get update"
    echo
    echo "    A version here but not the one you want? It is probably in another"
    echo "    channel. Switch with --channel and re-run --list."
    exit 0 ;;
esac

# ---------------------------------------------------------------------- apply --

[ "$(id -u)" -eq 0 ] || { echo "--apply needs root (sudo $0 --apply)" >&2; exit 1; }

BEFORE=$(dpkg-query -W -f='${Version}' gnosisvpn 2>/dev/null || echo "<none>")
say "before: $BEFORE"

say "unholding"
apt-mark unhold gnosisvpn >/dev/null 2>&1 || true

say "selecting channel=$CHANNEL network=$NETWORK"
# --channel is passed ALWAYS, never omitted: omitting it means stable, which
# would quietly downgrade a snapshot install.
curl -fsSL https://download.gnosisvpn.io/linux/install.sh \
  | bash -s -- --channel="$CHANNEL" --network="$NETWORK"

if [ -n "$PIN_VERSION" ]; then
  say "pinning to $PIN_VERSION"
  # --allow-downgrades because moving BACK to a known-good build is a normal
  # thing to want mid-investigation, and apt refuses it otherwise.
  apt-get install -y --allow-downgrades "gnosisvpn=$PIN_VERSION" || {
    echo "    failed. Available versions:" >&2
    apt-cache madison gnosisvpn | sed 's/^/      /' >&2
    exit 1; }
fi

say "re-holding"
apt-mark hold gnosisvpn >/dev/null

AFTER=$(dpkg-query -W -f='${Version}' gnosisvpn 2>/dev/null || echo "<none>")
say "after: $AFTER"

{ echo "recorded: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gnosis_vpn-ctl -V 2>&1
  echo "channel: $CHANNEL  network: $NETWORK  pin: ${PIN_VERSION:-<newest>}"
  echo "package: $AFTER (was $BEFORE)"
} > "$BUILD_FILE"
echo "    recorded in $BUILD_FILE"

say "service"
systemctl restart gnosisvpn
sleep 5
systemctl is-active gnosisvpn || true
journalctl -u gnosisvpn -n 20 --no-pager 2>/dev/null | grep -iE 'error|panic|config' || true

if [ "$BEFORE" != "$AFTER" ]; then
  cat <<EOF

    VERSION CHANGED -- two things to re-check before trusting any measurement:

    1. The pinned arms depend on protocol.path_planner keys (max_cached_paths,
       return_path_exploration). HoprLibConfig is deny_unknown_fields, so if
       those were renamed the service refuses to start with the arm's hopr.yaml
       rather than warning. Re-run the arm validation:
         sudo ./setup/02-make-arms.sh --out ./arms --destination ${GVPN_DESTINATION:-UK}
       then the validation block it prints.

    2. Results from the old build are NOT comparable with results from this one.
       Start a fresh run directory; do not pool them.
EOF
fi
