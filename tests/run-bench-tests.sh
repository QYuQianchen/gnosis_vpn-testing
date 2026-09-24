#!/usr/bin/env bash
# Run the real bench -- a --trial of the shipped study -- in a sandbox, with the
# VPN client, systemd and the network stubbed. Everything else is the real code:
# study loading, arm rendering, config install and rollback, interleaving,
# transfer legs, samplers, the dead-man switch, cleanup, and the report.
#
# Exists because gvpn-bench.sh was only ever syntax-checked, and a refactor
# shipped with a variable used but no longer assigned; under `set -u` the first
# real trial died on it.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(cd "$(mktemp -d)" && pwd -P)"; trap '[ -n "${KEEP:-}" ] && echo "sandbox kept: $SB" || rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/etc" "$SB/log" "$SB/state"
LOG="$SB/log/gnosisvpn.log"; : > "$LOG"
cp "$KIT/tests/fixtures/config-network.toml" "$SB/etc/config-jura-prod.toml"
ln -s "$SB/etc/config-jura-prod.toml" "$SB/etc/config.toml"

# --- gnosis_vpn-ctl: a tiny state machine; logs planner lines like the real one
cat > "$SB/bin/gnosis_vpn-ctl" <<EOF
#!/bin/bash
S="$SB/ctl.state"; [ -f "\$S" ] || echo idle > "\$S"
while [ "\${1:-}" = "-o" ]; do shift 2; done
cfg="\$(readlink -f "$SB/etc/config.toml")"
case "\${1:-}" in
  start-client) echo ready > "\$S" ;;
  stop-client)  echo idle > "\$S" ;;
  connect)      echo "connected \$2" > "\$S"; echo "Connecting to \$2"
                n=3; grep -q '^max_cached_paths = 1' "\$cfg" && n=1
                for r in \$(seq 1 \$n); do
                  echo "\$(date -u +%FT%TZ) DEBUG hopr_transport::path::planner: weighted candidate path kind=\"fill\" destination=0xdd hops=1 path=0x\${r}a -> 0xdd cost=0.\$RANDOM composite_weight=0.5 sampling_probability=\$(python3 -c "print(1/\$n)")" >> "$LOG"
                done
                echo "\$(date -u +%FT%TZ) DEBUG hopr_transport::path::planner: drawing return paths from tempered weights count=4 candidates=\$n" >> "$LOG" ;;
  disconnect)   grep -q connected "\$S" && echo ready > "\$S" ;;
  status)       st=\$(cat "\$S")
                case "\$st" in
                  idle)        echo "Worker offline" ;;
                  ready)       echo "Ready (Node is running) - traffic: Good, gas: Good"
                               echo "UK (Exit: 0x$(printf '0%.0s' $(seq 40)), Route: x)" ;;
                  connected*)  echo "Ready (Node is running) - traffic: Good, gas: Good"
                               echo "---"; echo "Connected to \${st#connected } (since 1s)" ;;
                esac ;;
  info)         echo "client service version: 0.96.2, package version: 2026.09.24+build.012613"
                echo "log file: $LOG" ;;
  telemetry)    echo "hopr_session_frame_completed_total 100"; echo "hopr_session_frame_discarded_total 1" ;;
  nerd-stats)   echo "{}" ;;
  -V|version)   echo "gnosis_vpn-ctl 0.96.2" ;;
  ping)         echo pong ;;
  destinations) echo UK ;;
esac
exit 0
EOF

# --- systemd: always healthy; flags as 00-vm-setup.sh installs them
cat > "$SB/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
  *is-active*)  exit 0 ;;
  *NRestarts*|*MainPID*|*ExecMainStatus*) echo 0 ;;
  *ExecStart*)  echo "ExecStart={ path=/usr/bin/gnosis_vpn-root ; argv[]=/usr/bin/gnosis_vpn-root --allow-insecure }" ;;
esac
exit 0
EOF

# --- curl: a download writes the requested bytes over ~2 s; an upload reports
cat > "$SB/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; up=0
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -X) up=1; shift 2 ;; -w|--data-binary|--max-time|-r) shift 2 ;;
               -*) shift ;; *) url="$1"; shift ;; esac
done
if [ "$up" = 1 ]; then echo "5242880 2.0"; exit 0; fi
n=$(printf '%s' "$url" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p'); n=${n:-5242880}
head -c $((n / 2)) /dev/zero > "$out"; sleep 1
head -c "$n" /dev/zero > "$out"; sleep 1
EOF

# --- ping: prints until SIGINT, then the statistics block, like the real one
cat > "$SB/bin/ping" <<'EOF'
#!/bin/bash
trap 'echo "--- 1.1.1.1 ping statistics ---"; echo "8 packets transmitted, 8 received, 0% packet loss, time 2000ms"; echo "rtt min/avg/max/mdev = 20.0/25.0/30.0/2.0 ms"; exit 0' INT
while :; do echo "64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=25.0 ms"; sleep 0.25; done
EOF
cat > "$SB/bin/dpkg-query" <<'EOF'
#!/bin/sh
echo "2026.09.24+build.012613"
EOF
cat > "$SB/bin/journalctl" <<'EOF'
#!/bin/sh
exit 0
EOF
command -v sysctl >/dev/null || printf '#!/bin/sh\necho bbr\n' > "$SB/bin/sysctl"
command -v ip     >/dev/null || printf '#!/bin/sh\nexit 0\n' > "$SB/bin/ip"
chmod +x "$SB/bin/"*

export PATH="$SB/bin:$PATH" GVPN_STATE="$SB/state" GVPN_CONFIG_DIR="$SB/etc" \
       GNOSISVPN_CONFIG_PATH="$SB/etc/config.toml" GVPN_SERVICE_LOG="$LOG" \
       GVPN_STUDY=2026-09-24-transfers-25mb GVPN_DESTINATION=UK
# As on the VM: the bench runs under sudo for a user who reads the results without it.
if id nobody >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
  export SUDO_USER=nobody; chmod 755 "$SB"
fi

fail=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
echo "bench (a real --trial, client and network stubbed)"

bash "$KIT/setup/02-make-arms.sh" >"$SB/arms.out" 2>&1 && ok "arms render" \
  || { bad "arms did not render"; cat "$SB/arms.out"; exit 1; }

# A lock left by a bench that died (here: a PID that is not running) must not
# block the next run -- the bench clears it and says so.
mkdir -p "$SB/state/runs/19990101-000000"; echo 999999 > "$SB/state/runs/19990101-000000/bench.pid"
ln -s "$SB/state/runs/19990101-000000" "$SB/state/run.lock"

timeout 600 bash "$KIT/bench/gvpn-bench.sh" --trial >"$SB/bench.out" 2>&1
rc=$?
grep -q 'clearing a stale run lock' "$SB/bench.out" && ok "a stale lock (dead bench) is cleared" \
  || bad "the stale lock was not cleared"
[ "$rc" = 0 ] && ok "trial exits 0" || { bad "trial exited $rc:"; tail -25 "$SB/bench.out" | sed 's/^/        /'; }
grep -q 'unbound variable' "$SB/bench.out" && bad "unbound variable: $(grep -m1 'unbound variable' "$SB/bench.out")"

RUN="$(ls -1dt "$SB/state/runs"/*/ 2>/dev/null | head -1)"; RUN="${RUN%/}"
[ -f "$RUN/manifest.json" ] && ok "manifest written" || bad "no manifest"
python3 - "$RUN/manifest.json" <<'PY' && ok "manifest records trial and pinned_arms=pin-planner" || bad "manifest fields wrong"
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if m.get("trial") is True and m.get("pinned_arms") == "pin-planner" else 1)
PY
n=$(awk -F, 'NR>1 && $NF=="ok"' "$RUN/summary.csv" 2>/dev/null | wc -l)
[ "$n" -ge 2 ] && ok "both arms completed a session ($n ok)" || { bad "only $n ok sessions"; cat "$RUN/summary.csv" 2>/dev/null; }
[ -f "$RUN/finished.json" ] && ok "finished.json written" || bad "no finished.json"
[ ! -e "$SB/state/run.lock" ] && ok "run lock released" || bad "run lock left behind"
[ "$(readlink "$SB/etc/config.toml")" = "$SB/etc/config-jura-prod.toml" ] \
  && ok "cleanup restored the network config" || bad "node left on an arm: $(readlink "$SB/etc/config.toml")"

# --detach (what `make launch` uses): the parent returns at once and hands the
# lock to the child, which must hold it -- live -- until it finishes.
DRUN="$(timeout 30 bash "$KIT/bench/gvpn-bench.sh" --trial --detach 2>"$SB/detach.err" | tail -1)"
sleep 2
st="$( . "$KIT/lib/common.sh"; gvpn_lock_state; echo "$GVPN_LOCK_STATE $GVPN_LOCK_RUN" )"
[ "$st" = "live $DRUN" ] && ok "a detached run holds a live lock" || bad "detached run: lock is '$st', want 'live $DRUN'"
for _ in $(seq 120); do [ -f "$DRUN/finished.json" ] && break; sleep 1; done
sleep 1
[ -f "$DRUN/finished.json" ] && [ ! -e "$SB/state/run.lock" ] && ok "the detached run finished and released the lock" \
  || bad "detached run: finished=$([ -f "$DRUN/finished.json" ] && echo y || echo n), lock=$(readlink "$SB/state/run.lock" 2>/dev/null)"

# An abort before cleanup() is installed -- how the first trial died, on an
# unbound variable -- must still release the lock, or every push is refused.
mkdir -p "$SB/kit2" && cp -a "$KIT/." "$SB/kit2/"
sed -i 's|^echo \$\$ > "\$RUN_DIR/bench.pid"$|&\n: "$GVPN_TEST_UNSET_VARIABLE"|' "$SB/kit2/bench/gvpn-bench.sh"
grep -q GVPN_TEST_UNSET_VARIABLE "$SB/kit2/bench/gvpn-bench.sh" || bad "could not plant the abort"
timeout 60 bash "$SB/kit2/bench/gvpn-bench.sh" --trial >"$SB/abort.out" 2>&1
grep -q 'unbound variable' "$SB/abort.out" && [ ! -e "$SB/state/run.lock" ] \
  && ok "an abort under set -u releases the run lock" \
  || bad "abort left the lock: $(readlink "$SB/state/run.lock" 2>/dev/null) / $(tail -1 "$SB/abort.out")"

# `make report` runs as the user, not root: it must be able to write into the run
# the root-run bench produced (the first real trial's report died on EACCES).
as_user() { if [ -n "${SUDO_USER:-}" ]; then runuser -u "$SUDO_USER" -- "$@"; else "$@"; fi; }
[ -z "${SUDO_USER:-}" ] || [ -z "$(find "$RUN" ! -user "$SUDO_USER" | head -1)" ] \
  && ok "the run directory is handed back to the sudo user" \
  || bad "root-owned files left in the run: $(find "$RUN" ! -user "$SUDO_USER" | head -3 | tr '\n' ' ')"
as_user python3 "$KIT/bench/gvpn-analyze.py" "$RUN" --floor-mbps 5 \
    --markdown "$RUN/report.md" --csv "$RUN/sessions.csv" >"$SB/report.out" 2>&1 \
  && ok "report renders as the user (report.md, sessions.csv)" || { bad "report failed"; tail -5 "$SB/report.out"; }
grep -q 'TRIAL RUN' "$SB/report.out" && ok "report marks it a trial" || bad "report does not say TRIAL RUN"
grep -q 'PIN DID NOT TAKE' "$SB/report.out" && bad "report voided a working pin" || ok "working pin is not voided"

echo; [ "$fail" = 0 ] && echo "all bench tests passed" || echo "FAILURES above"; exit $fail
