#!/usr/bin/env bash
#
# 00-vm-setup.sh -- prepare a clean Contabo Ubuntu VM to run the #8408 benchmark.
#
# Run as root on the VM under test. Idempotent: safe to re-run.
#
#   sudo ./00-vm-setup.sh --network jura-prod
#
# What it does, and why each step is here:
#
#   1. Packages         iperf3, python3, jq, chrony, sysstat, tcpdump, iproute2.
#                       chrony is not optional: relay-side metrics are joined to
#                       client sessions on wall-clock time, and an unsynced VM
#                       clock silently destroys that join.
#   2. Gnosis VPN       official APT installer, pinned to a network, then held so
#                       an unattended upgrade cannot swap the binary mid-run.
#   3. SSH survival     a policy route that keeps traffic sourced from the VM's
#                       public IP off the tunnel. Without it, bringing up a
#                       full-tunnel VPN on a remote box drops your own session.
#                       This is a deliberate privacy hole; fine on a throwaway
#                       test VM, never on a real one.
#   4. Logging          a size-based logrotate override. The planner DEBUG logging
#                       the experiment needs produces ~100 MB in under an hour,
#                       and the shipped daily rotation loses the interesting lines
#                       (this is exactly what happened in the 2026-09-08 run).
#   5. Drop-ins         RUST_LOG for path attribution, and optional --allow-insecure
#                       / --allow-experimental, which are CLI-only flags with no
#                       env-var equivalent -- so a 0-hop arm needs a unit override.
#
set -euo pipefail

# gvpn.conf carries the channel, network, pinned version and run defaults, so a
# change of build is a one-line edit that is version-controlled rather than a
# command someone has to remember to retype. `set -a` exports what it sets, which
# is what lets the bench script inherit the same values. Flags still win: they are
# parsed after this.
CONFIG_FILE="${GVPN_CONFIG:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/gvpn.conf}"
if [ -r "$CONFIG_FILE" ]; then
  set -a; . "$CONFIG_FILE"; set +a
  CONFIG_LOADED="$CONFIG_FILE"
else
  CONFIG_LOADED=""
fi

NETWORK="${GVPN_NETWORK:-jura-prod}"
CHANNEL="${GVPN_CHANNEL:-stable}"
PIN_VERSION="${GVPN_PIN_VERSION:-}"
ENABLE_INSECURE="${GVPN_ALLOW_INSECURE:-0}"
ENABLE_EXPERIMENTAL="${GVPN_ALLOW_EXPERIMENTAL:-0}"
SKIP_SSH_BYPASS=0
KEEP_AUTO_UPGRADES=0      # freeze unattended-upgrades during the benchmark
LOG_SIZE="${GVPN_LOG_SIZE:-200M}"
LOG_KEEP="${GVPN_LOG_KEEP:-20}"

usage() {
  cat <<EOF
00-vm-setup.sh -- prepare a clean Ubuntu VM for the #8408 benchmark

Usage: sudo $0 [options]

  --network NAME        jura-prod (default) | jura-dev | piz-palu-dev
  --channel NAME        stable (default) | snapshot | experimental
                        note: piz-palu-dev only exists on the experimental channel
  --allow-insecure      add --allow-insecure to the service (enables 0-hop arms)
  --allow-experimental  add --allow-experimental (enables 2+ hop arms)
  --skip-ssh-bypass     do NOT install the policy route that keeps SSH alive
  --keep-auto-upgrades  leave unattended-upgrades enabled (default: disable it for
                        the run -- it takes the dpkg lock and can restart services
                        mid-soak)
  --log-size SIZE       rotate the service log at this size (default: $LOG_SIZE)
  --config PATH         config file to read (default: ../gvpn.conf next to this script)
  -h, --help

Defaults come from gvpn.conf; flags override it. Current config: ${CONFIG_LOADED:-<none found>}
  channel=$CHANNEL network=$NETWORK pin=${PIN_VERSION:-<newest in channel>}
  allow_insecure=$ENABLE_INSECURE allow_experimental=$ENABLE_EXPERIMENTAL

After this script, run:
  ./01-iperf-server.sh        # on the OTHER VPS, not this one
  ./02-make-arms.sh --help    # build the arm configs
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --network)             NETWORK="$2"; shift 2 ;;
    --channel)             CHANNEL="$2"; shift 2 ;;
    --allow-insecure)      ENABLE_INSECURE=1; shift ;;
    --allow-experimental)  ENABLE_EXPERIMENTAL=1; shift ;;
    --skip-ssh-bypass)     SKIP_SSH_BYPASS=1; shift ;;
    --keep-auto-upgrades)  KEEP_AUTO_UPGRADES=1; shift ;;
    --log-size)            LOG_SIZE="$2"; shift 2 ;;
    --config)              shift 2 ;;   # consumed above, before defaults
    -h|--help)             usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo $0 ...)" >&2; exit 1; }

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# A fresh Ubuntu VM runs unattended-upgrades within minutes of first boot, and it
# holds the dpkg lock while it does. Any apt call that collides with it dies with
# "Could not get lock /var/lib/dpkg/lock-frontend", which under `set -e` aborts
# this script halfway through -- leaving the SSH policy route and the logging
# config uninstalled, which is the dangerous half to be missing.
wait_apt_lock() {
  local waited=0 limit="${GVPN_APT_LOCK_WAIT:-600}"
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock \
        >/dev/null 2>&1; do
    [ "$waited" = 0 ] && echo "    waiting for another apt/dpkg process to finish..."
    sleep 5
    waited=$(( waited + 5 ))
    if [ "$waited" -ge "$limit" ]; then
      echo "    still locked after ${limit}s. Find the holder and deal with it:" >&2
      echo "      sudo fuser -v /var/lib/dpkg/lock-frontend" >&2
      echo "      systemctl status unattended-upgrades apt-daily.service apt-daily-upgrade.service" >&2
      return 1
    fi
  done
  [ "$waited" -gt 0 ] && echo "    lock released after ${waited}s"
  return 0
}

# ---------------------------------------------------------------- 1. packages --

say "freezing automatic upgrades for the duration of the benchmark"
if [ "$KEEP_AUTO_UPGRADES" = 0 ]; then
  # Two reasons, both real: it takes the dpkg lock out from under this script, and
  # a package upgrade part-way through a 36-hour soak can restart services and
  # silently invalidate everything measured after it.
  systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
  systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  echo "    disabled unattended-upgrades and the apt-daily timers"
  echo "    RE-ENABLE WHEN THE BENCHMARK IS OVER:"
  echo "      sudo systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer"
else
  echo "    left enabled (--keep-auto-upgrades); expect occasional dpkg lock waits"
fi

say "installing packages"
export DEBIAN_FRONTEND=noninteractive
wait_apt_lock || exit 1
apt-get update -qq
wait_apt_lock || exit 1
apt-get install -y -qq \
  iperf3 python3 jq curl ca-certificates gnupg \
  chrony sysstat tcpdump iproute2 ethtool \
  logrotate psmisc bc >/dev/null

# The iperf3 package ships a server unit. This box is the CLIENT; the server lives
# on the far-end VPS. Keep it off so it cannot hold a port or burn CPU mid-run.
systemctl disable --now iperf3.service >/dev/null 2>&1 || true

# The join between client sessions and relay metrics is wall-clock based.
systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true
# sysstat's collector gives per-core CPU history, which is how a saturated Rayon
# pool is distinguished from a genuinely busy box.
sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat 2>/dev/null || true
systemctl enable --now sysstat >/dev/null 2>&1 || true

say "clock status"
timedatectl show -p NTPSynchronized --value 2>/dev/null || true
chronyc tracking 2>/dev/null | head -3 || true

# ------------------------------------------------------------- 2. gnosis vpn --

if ! command -v gnosis_vpn-ctl >/dev/null 2>&1; then
  say "installing Gnosis VPN (channel=$CHANNEL network=$NETWORK)"
  # The installer runs its own apt-get, so it needs the lock free too.
  wait_apt_lock || exit 1
  curl -fsSL https://download.gnosisvpn.io/linux/install.sh \
    | bash -s -- --channel="$CHANNEL" --network="$NETWORK"
  if [ -n "$PIN_VERSION" ]; then
    say "pinning to gnosisvpn=$PIN_VERSION"
    wait_apt_lock || exit 1
    apt-get install -y --allow-downgrades "gnosisvpn=$PIN_VERSION" \
      || echo "    could not install $PIN_VERSION -- see: apt-cache madison gnosisvpn" >&2
  fi
else
  say "Gnosis VPN already installed: $(gnosis_vpn-ctl -V 2>&1)"
  echo "    (to switch network: curl -fsSL https://download.gnosisvpn.io/linux/install.sh | sudo bash -s -- --channel=$CHANNEL --network=$NETWORK)"
fi

# A 2-day unattended run must not have the binary swapped under it.
say "holding the gnosisvpn package against unattended upgrades"
apt-mark hold gnosisvpn >/dev/null 2>&1 || true

# ---------------------------------------------------------- 3. SSH survival --
#
# A full-tunnel VPN replaces the default route. Inbound SSH still arrives, but the
# reply is routed into the tunnel and never gets back -- the connection dies and
# so does your access to the VM. The fix is a source-based policy route: anything
# whose source address is the VM's own public IP goes out the physical interface.

install_ssh_bypass() {
  local ifc gw ip4
  ifc=$(ip -4 route show default | awk '/default/{print $5; exit}')
  gw=$(ip -4 route show default | awk '/default/{print $3; exit}')
  ip4=$(ip -4 -o addr show dev "$ifc" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$ifc" ] && [ -n "$gw" ] && [ -n "$ip4" ] || { echo "could not detect default route; skipping"; return 1; }

  cat > /usr/local/sbin/gvpn-ssh-bypass.sh <<EOF
#!/bin/sh
# Keep traffic sourced from the VM's public IP off the VPN tunnel, so inbound
# SSH survives while the tunnel is up. Test VM only -- this traffic is NOT private.
IF=$ifc; GW=$gw; IP=$ip4; TBL=200
ip rule del from \$IP table \$TBL 2>/dev/null || true
ip rule add from \$IP table \$TBL priority 100
ip route replace default via \$GW dev \$IF table \$TBL
EOF
  chmod +x /usr/local/sbin/gvpn-ssh-bypass.sh

  cat > /etc/systemd/system/gvpn-ssh-bypass.service <<'EOF'
[Unit]
Description=Keep SSH reachable while the Gnosis VPN tunnel is up (test VM only)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/gvpn-ssh-bypass.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now gvpn-ssh-bypass.service
  echo "    policy route installed: from $ip4 -> table 200 via $gw dev $ifc"
  echo "    VERIFY IT before starting a long run:"
  echo "      1. gnosis_vpn-ctl connect <destination>"
  echo "      2. from another machine: ssh root@$ip4 'echo still-here'"
  echo "    If that fails, the dead-man switch is your only way back -- and"
  echo "    Contabo's VNC console is the fallback. Do not start a soak run first."
}

if [ "$SKIP_SSH_BYPASS" = 0 ]; then
  say "installing the SSH bypass policy route"
  install_ssh_bypass || true
else
  say "skipping SSH bypass (--skip-ssh-bypass)"
  echo "    the dead-man switch in gvpn-bench.sh is then your ONLY way back in."
fi

# --------------------------------------------------------------- 4. logging --

say "size-based log rotation (${LOG_SIZE}, keep ${LOG_KEEP})"
mkdir -p /etc/logrotate.d
cat > /etc/logrotate.d/gnosisvpn-bench <<EOF
# Overrides the packaged daily rotation for the duration of the benchmark.
# Planner DEBUG logging produces ~100 MB/hour; daily rotation loses the lines
# the experiment is actually about. Remove this file when the run is over.
/var/log/gnosisvpn/gnosisvpn.log {
    size ${LOG_SIZE}
    rotate ${LOG_KEEP}
    missingok
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF

# logrotate only runs on its timer; for a heavy run, check it every 10 minutes.
cat > /etc/systemd/system/gvpn-logrotate.timer <<'EOF'
[Unit]
Description=Frequent logrotate while the Gnosis VPN benchmark is running
[Timer]
OnBootSec=10min
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/gvpn-logrotate.service <<'EOF'
[Unit]
Description=Rotate the Gnosis VPN service log
[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/gnosisvpn-bench
EOF
systemctl daemon-reload
systemctl enable --now gvpn-logrotate.timer >/dev/null 2>&1 || true

DISK_FREE=$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')
if [ "${DISK_FREE:-0}" -lt 20 ]; then
  echo "    WARNING: only ${DISK_FREE}G free on /var. DEBUG logging needs room;"
  echo "             reduce --log-size/--log-keep or attach more disk."
fi

# ------------------------------------------------------------- 5. drop-ins --
#
# RUST_LOG goes in a drop-in rather than /etc/gnosisvpn/gnosisvpn.env, because the
# packaged env file is owned by apt and would be replaced on upgrade. A drop-in's
# Environment= is applied after the unit's EnvironmentFile=, so it wins.

say "systemd drop-ins"
mkdir -p /etc/systemd/system/gnosisvpn.service.d

cat > /etc/systemd/system/gnosisvpn.service.d/10-bench-logging.conf <<'EOF'
[Service]
# Path attribution. These two targets emit the "weighted candidate path" and
# "[forward]/[return] candidate path" lines the analysis counts distinct relays
# from. Only these two -- full DEBUG buries them.
Environment=RUST_LOG=info,hopr_transport::path::planner=debug,hopr_transport::path::selector=debug
EOF

FLAGS=""
[ "$ENABLE_INSECURE" = 1 ]     && FLAGS="$FLAGS --allow-insecure"
[ "$ENABLE_EXPERIMENTAL" = 1 ] && FLAGS="$FLAGS --allow-experimental"
if [ -n "$FLAGS" ]; then
  cat > /etc/systemd/system/gnosisvpn.service.d/20-bench-flags.conf <<EOF
[Service]
# --allow-insecure and --allow-experimental are CLI-only: the binary exposes no
# env var for them, so the only way in is to replace ExecStart. The empty
# assignment is required to clear the unit's own ExecStart first.
ExecStart=
ExecStart=/usr/bin/gnosis_vpn-root$FLAGS
EOF
  echo "    service flags:$FLAGS"
else
  rm -f /etc/systemd/system/gnosisvpn.service.d/20-bench-flags.conf
  echo "    no extra service flags (0-hop and 2+hop arms will be refused)"
fi

systemctl daemon-reload
systemctl restart gnosisvpn
sleep 3

# ----------------------------------------------------------------- summary --

say "state"
systemctl is-active gnosisvpn && gnosis_vpn-ctl -V 2>&1 || true
# The build identity belongs with the results, not in someone's shell history.
{ echo "recorded: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gnosis_vpn-ctl -V 2>&1
  echo "channel: $CHANNEL  network: $NETWORK  pin: ${PIN_VERSION:-<newest>}"
  dpkg-query -W -f='package: ${Package} ${Version}\n' gnosisvpn 2>/dev/null
} > "$(dirname "$0")/../BUILD.txt" 2>/dev/null || true
echo
echo "config:       /etc/gnosisvpn/config.toml"
echo "identity dir: /var/lib/gnosisvpn/.config"
echo "service log:  /var/log/gnosisvpn/gnosisvpn.log"
echo "cc (local):   $(sysctl -n net.ipv4.tcp_congestion_control)"
echo
echo "Next:"
echo "  1. ./01-iperf-server.sh          on the far-end VPS (different AS)"
echo "  2. ./02-make-arms.sh --help      build the arm configs"
echo "  3. gnosis_vpn-ctl start-client 30m && gnosis_vpn-ctl status"
echo "     -- onboard once and reach Ready before benchmarking anything"
echo "  4. VERIFY SSH SURVIVES A CONNECT (see above) before any long run"
