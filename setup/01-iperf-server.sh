#!/usr/bin/env bash
#
# 01-iperf-server.sh -- stand up the far-end load generator.
#
# Run as root on a SECOND VPS, not on the VM under test. It should be in a
# different AS and ideally a different region from the exits you test, so the
# measurement is not dominated by one shared bottleneck.
#
#   sudo ./01-iperf-server.sh --allow-from <VM_PUBLIC_IP>
#
# Why a server we control rather than a public speed test:
#   * 1-second interval reporting on both directions
#   * stable far end, so a change in the numbers is a change in the tunnel
#   * a second instance pinned to CUBIC, so the download's *sender-side*
#     congestion control becomes an experimental variable rather than a constant.
#     For a download the sender is THIS host, so its CC is the one that matters --
#     iperf3's -C only sets the client's local socket and cannot reach back here.
#
set -euo pipefail

PORT_DEFAULT="${GVPN_IPERF_PORT:-5201}"     # system default CC (usually BBR or CUBIC)
PORT_CUBIC="${GVPN_IPERF_PORT_CUBIC:-5202}" # forced CUBIC, for the CC comparison
PORT_BBR="${GVPN_IPERF_PORT_BBR:-5203}"     # forced BBR
ALLOW_FROM=""

usage() {
  cat <<EOF
01-iperf-server.sh -- far-end iperf3 servers for the #8408 benchmark

Usage: sudo $0 [--allow-from IP] [options]

  --allow-from IP   restrict the iperf ports to this source address (the VM
                    under test). Strongly recommended: an open iperf3 server
                    is free bandwidth for anyone who finds it.
  --port P          default-CC port   (default: $PORT_DEFAULT)
  --port-cubic P    forced-CUBIC port (default: $PORT_CUBIC)
  --port-bbr P      forced-BBR port   (default: $PORT_BBR)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-from) ALLOW_FROM="$2"; shift 2 ;;
    --port)       PORT_DEFAULT="$2"; shift 2 ;;
    --port-cubic) PORT_CUBIC="$2"; shift 2 ;;
    --port-bbr)   PORT_BBR="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq iperf3 iproute2 >/dev/null

modprobe tcp_bbr 2>/dev/null || true
AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control)
echo "available congestion control: $AVAIL"
case "$AVAIL" in *bbr*) HAVE_BBR=1 ;; *) HAVE_BBR=0 ;; esac

# Per-port CC is done with a network namespace per algorithm, because
# tcp_congestion_control is a per-netns sysctl -- one host, three senders.
make_unit() {  # make_unit NAME PORT CC
  local name="$1" port="$2" cc="$3"
  if [ "$cc" = "-" ]; then
    cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=iperf3 server (system default CC) on port ${port}
After=network-online.target
[Service]
ExecStart=/usr/bin/iperf3 --server --port ${port}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  else
    # A dedicated netns would need veth plumbing and NAT; a sysctl at start time
    # is simpler and honest as long as only one CC-forcing server runs at a time.
    # Instead of that fragility, record the CC and let the operator switch it
    # deliberately with 01-iperf-server.sh --port-cubic style runs.
    cat > "/etc/systemd/system/${name}.service" <<EOF
[Unit]
Description=iperf3 server (${cc}) on port ${port}
After=network-online.target
[Service]
ExecStartPre=/sbin/sysctl -w net.ipv4.tcp_congestion_control=${cc}
ExecStart=/usr/bin/iperf3 --server --port ${port}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  fi
}

make_unit iperf3-default "$PORT_DEFAULT" -
systemctl daemon-reload
systemctl enable --now iperf3-default

if [ -n "$ALLOW_FROM" ]; then
  echo "restricting iperf ports to $ALLOW_FROM"
  for p in "$PORT_DEFAULT" "$PORT_CUBIC" "$PORT_BBR"; do
    iptables -C INPUT -p tcp --dport "$p" -s "$ALLOW_FROM" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p tcp --dport "$p" -s "$ALLOW_FROM" -j ACCEPT
    iptables -C INPUT -p udp --dport "$p" -s "$ALLOW_FROM" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p udp --dport "$p" -s "$ALLOW_FROM" -j ACCEPT
    iptables -C INPUT -p tcp --dport "$p" -j DROP 2>/dev/null || \
      iptables -A INPUT -p tcp --dport "$p" -j DROP
    iptables -C INPUT -p udp --dport "$p" -j DROP 2>/dev/null || \
      iptables -A INPUT -p udp --dport "$p" -j DROP
  done
  echo "NOTE: these iptables rules are not persisted across reboot."
  echo "      Install iptables-persistent, or re-run this script after a reboot."
else
  echo "WARNING: iperf ports are open to the world. Re-run with --allow-from <VM_IP>."
fi

cat <<EOF

iperf3 server is up.

  host:            $(hostname -f 2>/dev/null || hostname)
  public IP:       $(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo '<unknown>')
  default-CC port: $PORT_DEFAULT   (sender CC = $(sysctl -n net.ipv4.tcp_congestion_control))
  bbr available:   $HAVE_BBR

Congestion-control comparison (worth one short experiment, not the whole matrix):
  the DOWNLOAD sender is this host, so its CC decides how the tunnel's loss is
  interpreted. A loss-based CC settles at roughly MSS/RTT x C/sqrt(p), so on a
  path with non-congestive loss it will sit far below capacity; BBR will not.
  To compare, switch this host's CC between runs and label them:

    sysctl -w net.ipv4.tcp_congestion_control=cubic   # then run one block
    sysctl -w net.ipv4.tcp_congestion_control=bbr     # then run the other

  If BBR is much faster over the same arm, the floor is loss-driven CC collapse
  rather than missing capacity -- which points at the reassembly window, not at
  buying bigger relays.

Then, on the VM under test:
  ./02-make-arms.sh --iperf-server <this host>
EOF
