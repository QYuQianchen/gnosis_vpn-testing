#!/usr/bin/env bash
#
# gvpn-bench.sh -- pinned-vs-auto path-finding benchmark for hoprnet/hoprnet#8408.
#
# Complements vpn-test.sh (which answers "does it connect and ping?") by answering
# "what does the throughput DISTRIBUTION look like, per routing arm, and where does
# its variance come from?".
#
# ---------------------------------------------------------------------------
# PROFILES -- one script, from a 6-minute smoke test to a 2-day soak
#
#   --profile smoke        1 cycle, 1 rep, 25 MB each way      ~6 min
#   --profile quick        3 cycles, 1 rep, 25 MB each way     ~35 min
#   --profile standard     30 cycles, 3 reps, 60s legs         ~12 h
#   --profile transfers    30 cycles, 1 rep, 25 MB each way     ~3 h (2 arms, 1 exit)
#   --profile soak         36h budget, 3 reps, 60s legs        ~1.5 days
#   --profile persistence  6 cycles, 5 reps x 25 MB, 5 min gaps
#                          -- one session held open across repeated transfers
#   --profile custom       nothing preset
#
# Any knob can be overridden after the profile flag.
#
# ---------------------------------------------------------------------------
# TWO MEASUREMENT MODES, not interchangeable
#
#   --mode bytes  (iperf3 -n)  fixed volume, measure the time. Matches the team's
#       existing 25 MB test and is closest to what a user feels. For a floor study
#       the catch is that a floored session takes LONGER, so sessions contribute
#       unequal sample counts and the schedule becomes load-dependent.
#       --leg-timeout bounds that; timed-out legs are counted, never dropped.
#
#   --mode time   (iperf3 -t)  fixed duration, measure the volume. Every session
#       contributes the same sample budget, so the per-arm distributions are
#       directly comparable and a multi-day schedule is predictable.
#
#   bytes for short runs and for comparability with existing numbers; time for
#   the statistical matrix.
#
# ---------------------------------------------------------------------------
# WHY REPEATS INSIDE ONE SESSION (--reps)
#
#   Repeating transfers without reconnecting splits the variance in two:
#     between-session -- which relays this identity has channels to, SURB warm-up,
#                        which exit, how onboarding went
#     within-session  -- the per-packet path draw and transient relay load
#   That decomposition is what answers "why are SOME sessions bad": does a bad
#   session stay bad for its whole life, or does it flicker? Nothing else here
#   answers it.
#
#   TCP state is controlled for, so the repeats measure the tunnel rather than
#   the congestion controller's memory:
#     * each rep is a new TCP connection (cwnd starts at IW10);
#     * `ip tcp_metrics flush` between reps, so a bad rep cannot seed a later
#       rep's initial ssthresh from the kernel's per-destination cache;
#     * a --rep-gap beyond one RTO also trips tcp_slow_start_after_idle, which
#       resets the window anyway.
#   What the gap deliberately does NOT reset is HOPR-side state: the SURB
#   balancer's estimate decays over minutes and the path cache turns over every
#   10 s, so a late rep is a fresh draw from a distribution that has itself moved.
#
# ---------------------------------------------------------------------------
# WHY A UDP LEG (--udp-seconds)
#
#   iperf3's UDP mode reports jitter and datagram loss directly, with no
#   congestion controller in the path. If UDP shows several percent loss while
#   TCP sits at a few Mbit/s, the diagnosis is loss-driven CC collapse rather
#   than missing capacity -- which points at the session reassembly window, not
#   at buying bigger relays.
#
#   It needs an iperf3 server, but it is NOT the only way to get that signal, and
#   arguably not the best one. Two others need no far end at all and are captured
#   on every run:
#     * the concurrent ping (ping.txt) -- loss and mdev jitter UNDER LOAD;
#     * the session telemetry -- hopr_session_frame_discarded_total,
#       time_to_finish_frame, retransmission requests. These have no congestion
#       controller in the loop either AND are scoped to the HOPR leg rather than
#       the whole internet path, which is what the study is actually about.
#
# ---------------------------------------------------------------------------
# LOAD SOURCE (--target)
#
#   iperf3  a server you control: both directions, exact interval reporting, and
#           the ability to set the SENDER's congestion control (which for a
#           download is the far end, not this box).
#   url     curl against a public endpoint. No second machine. Download only by
#           default. The per-second series comes from sampling the output file's
#           byte counter, so the analyser reads it exactly like iperf3 output.
#
# ---------------------------------------------------------------------------
# OTHER DESIGN POINTS
#
#   * ARMS ARE INTERLEAVED, NOT BLOCKED. Production relay load varies by hour, so
#     running arm A for an hour and arm B for the next hour measures the hour.
#   * THE STATISTIC IS THE TAIL, NOT THE MEAN. --interval 1, raw JSON kept.
#   * TELEMETRY IS SAMPLED ALONGSIDE, on the same wall clock, for the whole
#     session including the gaps between reps.
#   * THE DEAD-MAN SWITCH IS NOT OPTIONAL. A full-tunnel VPN on a remote VM takes
#     your own SSH path with it. Lifted from vpn-test.sh.
#
# Arm directory (see 02-make-arms.sh):
#     config.toml           -> /etc/gnosisvpn/config.toml
#     config.toml           -> the whole arm, including [connection.path_planner]
#     env                   -> extra systemd Environment= lines
#     flags                 -> service flags this arm needs (informational)
#
# Dependencies: bash, coreutils, curl, iperf3, ping, iproute2, gnosis_vpn-ctl.
#
set -uo pipefail
VERSION=0.4.0

# Kit root, used only to stamp the run with the script revision that produced it.
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo .)"
# Kit root, state directory, gvpn.conf and any GVPN_STUDY override.
. "$KIT/lib/common.sh"

# ---------------------------------------------------------------- defaults --

PROFILE="${GVPN_PROFILE:-quick}"

# Rendered arm instances, in the state directory -- never the repo's templates,
# which carry no addresses and are not runnable as-is.
ARMS_DIR="$GVPN_ARMS_DIR"
# Was flag-only, so a study file's GVPN_ARMS was read by nothing and the run
# silently fell back to "every directory in the arms dir". After a
# `make arms --pin-relay`, that silently includes the pin-cfg pair -- which
# trims the node's channels and contaminates every other arm in the study.
ARMS="${GVPN_ARMS:-}"
CYCLES=""
DURATION=""
DESTINATION="${GVPN_DESTINATION:-}"
# Exit as a DIMENSION, not a constant: "UK USA India" runs every arm against every
# exit each cycle, so pinned-vs-auto can be read per exit. Empty falls back to
# DESTINATION, or to the first the service reports.
DESTINATIONS="${GVPN_DESTINATIONS:-}"

MODE=""
DL_BYTES=""; UL_BYTES=""
DL_SECONDS=""; UL_SECONDS=""
LEG_TIMEOUT=""
REPS=""
REP_GAP=""
UDP_SECONDS=""
UDP_RATE="${GVPN_UDP_RATE:-10M}"
FLUSH_TCP_METRICS="${GVPN_FLUSH_TCP_METRICS:-1}"

# Load source. "iperf3" needs a server you control; "url" needs nothing but the
# tunnel itself -- curl pulls a fixed volume from a public endpoint and the byte
# counter is sampled once a second, producing the same shape iperf3 --interval 1
# does, so the analyser needs no special case.
TARGET="${GVPN_TARGET:-url}"             # url (no second machine) | iperf3
# {bytes} is substituted with the wanted volume. Cloudflare's endpoint returns
# exactly N bytes, which is what makes bytes-mode exact without Range requests.
DL_URL="${GVPN_DL_URL:-https://speed.cloudflare.com/__down?bytes={bytes}}"
# Cloudflare's speedtest upload endpoint, so url mode measures BOTH directions
# without a second machine. Set empty to skip the upload leg.
UL_URL="${GVPN_UL_URL:-https://speed.cloudflare.com/__up}"
UDP_HOST="${GVPN_UDP_HOST:-}"            # iperf3 host for the UDP leg only

IPERF_SERVER="${GVPN_IPERF_SERVER:-}"
IPERF_PORT="${GVPN_IPERF_PORT:-5201}"

PING_TARGET="${GVPN_PING_TARGET:-1.1.1.1}"
PING_INTERVAL="${GVPN_PING_INTERVAL:-0.25}"

# Raw output lives in the state directory, outside the git worktree: a soak is
# many GB of planner DEBUG logging, and anything inside the worktree is one
# deploy or one `git clean -fdx` from gone.
OUT_ROOT="${GVPN_OUT_ROOT:-$GVPN_RUNS_DIR}"

# Left by kits before the config.toml fix; removed on every arm switch.
LEGACY_ARM_FILES="/etc/systemd/system/gnosisvpn.service.d/30-arm.conf /etc/gnosisvpn/hopr-arm.yaml"
CTL="${GVPN_CTL:-gnosis_vpn-ctl}"

TELEMETRY_INTERVAL="${GVPN_TELEMETRY_INTERVAL:-5}"
NERD_INTERVAL="${GVPN_NERD_INTERVAL:-2}"

CONNECT_TIMEOUT="${GVPN_CONNECT_TIMEOUT:-300}"
DISCONNECT_TIMEOUT="${GVPN_DISCONNECT_TIMEOUT:-90}"
SERVICE_TIMEOUT="${GVPN_SERVICE_TIMEOUT:-120}"
ONBOARD_TIMEOUT="${GVPN_ONBOARD_TIMEOUT:-600}"
CTL_TIMEOUT="${GVPN_CTL_TIMEOUT:-30}"
COOLDOWN="${GVPN_COOLDOWN:-30}"
KEEPALIVE="${GVPN_KEEPALIVE:-60m}"

DEADMAN_MARGIN="${GVPN_DEADMAN_MARGIN:-120}"
DEADMAN_HARD=""

ASSUME_MBPS="${GVPN_ASSUME_MBPS:-5}"
CONNECT_EST="${GVPN_CONNECT_EST:-40}"

DETACH=0

# A rehearsal of THIS study rather than a different study. It keeps the arms,
# the exits and the load source exactly as configured and shrinks only the
# amount of work, so what it exercises is the real config path: the arm configs,
# the interleaving, the connect/disconnect cycle, the report, the publish step.
# A smaller --profile would exercise a DIFFERENT configuration, which is how a
# rehearsal passes and the real run then fails on the first cycle.
TRIAL="${GVPN_TRIAL:-0}"
DRY_RUN=0

usage() {
  cat <<EOF
gvpn-bench.sh $VERSION -- pinned-vs-auto path benchmark (hoprnet#8408)

Usage: $0 [--profile NAME] [--target url|iperf3 [-s HOST]] [options]

Profiles:
  smoke        1 cycle,  1 rep,  bytes 25M        ~6 min    rig check
  quick        3 cycles, 1 rep,  bytes 25M        ~35 min   signal check
  standard     30 cycles, 3 reps, time 60s/30s    ~12 h     the matrix
  soak         36h budget, 3 reps, time 60s/30s   ~1.5 d    unattended
  persistence  6 cycles, 5 reps x 25M, 5min gaps  ~5 h      within-session stability
  custom       no presets

Scheduling:
  -n, --cycles N          round-robin cycles (sessions per arm)
      --duration T        run whole cycles until the budget is spent (36h, 90m, 2d)

Measurement:
      --mode bytes|time   fixed volume, or fixed duration
      --dl-bytes SIZE     download volume, mode=bytes (25M, 100M, 1G)
      --ul-bytes SIZE     upload volume, mode=bytes
      --dl-seconds S      download duration, mode=time
      --ul-seconds S      upload duration, mode=time
      --reps N            transfers per session, without reconnecting
      --rep-gap T         idle between reps (20s, 5m)
      --target iperf3|url load source (default: iperf3)
      --url URL           url mode: download endpoint; {bytes} is substituted
      --url-up URL        url mode: optional POST endpoint for an upload leg
      --udp-host HOST     iperf3 host for the UDP leg only -- lets url mode still
                          measure jitter/loss against a public iperf3 server
      --udp-seconds S     UDP probe per rep for jitter/loss; 0 disables
      --udp-rate R        UDP offered rate (default: $UDP_RATE)
      --no-flush-metrics  keep the kernel TCP metrics cache between reps
      --leg-timeout S     hard cap per iperf3 leg

Setup:
      --arms-dir DIR      (default: $ARMS_DIR)
  -a, --arms "x y"        arms to cycle (default: all in --arms-dir)
  -D, --destination ID    single exit destination
      --destinations "A B"  compare across several exits; every arm runs against
                          every exit each cycle (multiplies the schedule)
  -s, --iperf-server H    iperf3 server (only with --target iperf3)
      --iperf-port P      (default: $IPERF_PORT)
  -o, --out DIR           (default: $OUT_ROOT)
      --dry-run           print the schedule and estimate, then exit
      --detach            re-exec detached; survives SSH loss
  -h, --help

Examples:
  $0 -s iperf.example.net --profile smoke
  $0 -s iperf.example.net --profile persistence          # the 5x25MB-with-pauses question
  $0 -s iperf.example.net --profile soak --detach
  $0 -s iperf.example.net --profile soak --mode bytes --dl-bytes 25M --duration 48h
EOF
}

# --------------------------------------------------------------- parsing --

parse_bytes() {
  local v="${1%B}" n unit
  n="${v%[KkMmGg]}"; unit="${v#"$n"}"
  case "$n" in ''|*[!0-9.]*) echo "bad size: $1" >&2; return 1 ;; esac
  case "$unit" in
    K|k) awk -v n="$n" 'BEGIN{printf "%d", n*1024}' ;;
    M|m) awk -v n="$n" 'BEGIN{printf "%d", n*1048576}' ;;
    G|g) awk -v n="$n" 'BEGIN{printf "%d", n*1073741824}' ;;
    '')  awk -v n="$n" 'BEGIN{printf "%d", n}' ;;
    *)   echo "bad size unit: $1" >&2; return 1 ;;
  esac
}

parse_duration() {
  local v="$1" n unit
  n="${v%[smhdSMHD]}"; unit="${v#"$n"}"
  case "$n" in ''|*[!0-9.]*) echo "bad duration: $1" >&2; return 1 ;; esac
  case "$unit" in
    s|S|'') awk -v n="$n" 'BEGIN{printf "%d", n}' ;;
    m|M)    awk -v n="$n" 'BEGIN{printf "%d", n*60}' ;;
    h|H)    awk -v n="$n" 'BEGIN{printf "%d", n*3600}' ;;
    d|D)    awk -v n="$n" 'BEGIN{printf "%d", n*86400}' ;;
    *)      echo "bad duration unit: $1" >&2; return 1 ;;
  esac
}

human_secs() { printf '%dd %dh %dm' $(( $1/86400 )) $(( ($1%86400)/3600 )) $(( ($1%3600)/60 )); }

apply_profile() {
  case "$1" in
    smoke)       : "${CYCLES:=1}";  : "${MODE:=bytes}"; : "${DL_BYTES:=25M}"; : "${UL_BYTES:=25M}"
                 : "${REPS:=1}"; : "${REP_GAP:=10}"; : "${UDP_SECONDS:=5}"; COOLDOWN=10 ;;
    quick)       : "${CYCLES:=3}";  : "${MODE:=bytes}"; : "${DL_BYTES:=25M}"; : "${UL_BYTES:=25M}"
                 : "${REPS:=1}"; : "${REP_GAP:=20}"; : "${UDP_SECONDS:=10}" ;;
    standard)    : "${CYCLES:=30}"; : "${MODE:=time}";  : "${DL_SECONDS:=60}"; : "${UL_SECONDS:=30}"
                 : "${REPS:=3}"; : "${REP_GAP:=20}"; : "${UDP_SECONDS:=10}" ;;
    soak)        : "${DURATION:=36h}"; : "${MODE:=time}"; : "${DL_SECONDS:=60}"; : "${UL_SECONDS:=30}"
                 : "${REPS:=3}"; : "${REP_GAP:=20}"; : "${UDP_SECONDS:=10}" ;;
    transfers)   : "${CYCLES:=30}"; : "${MODE:=bytes}"; : "${DL_BYTES:=25M}"; : "${UL_BYTES:=25M}"
                 : "${REPS:=1}"; : "${REP_GAP:=20}"; : "${UDP_SECONDS:=10}" ;;
    persistence) : "${CYCLES:=6}";  : "${MODE:=bytes}"; : "${DL_BYTES:=25M}"; : "${UL_BYTES:=25M}"
                 : "${REPS:=5}"; : "${REP_GAP:=5m}"; : "${UDP_SECONDS:=10}"; : "${KEEPALIVE:=120m}" ;;
    custom)      : ;;
    *) echo "unknown profile: $1 (smoke|quick|standard|transfers|soak|persistence|custom)" >&2; exit 2 ;;
  esac
}

for i in $(seq 1 $#); do
  eval "a=\${$i}"
  [ "$a" = "--profile" ] && eval "PROFILE=\${$(( i + 1 ))}"
done

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)           shift 2 ;;
    --arms-dir)          ARMS_DIR="$2"; shift 2 ;;
    -a|--arms)           ARMS="$2"; shift 2 ;;
    -n|--cycles)         CYCLES="$2"; shift 2 ;;
    --duration)          DURATION="$2"; shift 2 ;;
    --mode)              MODE="$2"; shift 2 ;;
    --dl-bytes)          DL_BYTES="$2"; shift 2 ;;
    --ul-bytes)          UL_BYTES="$2"; shift 2 ;;
    --dl-seconds)        DL_SECONDS="$2"; shift 2 ;;
    --ul-seconds)        UL_SECONDS="$2"; shift 2 ;;
    --reps)              REPS="$2"; shift 2 ;;
    --rep-gap)           REP_GAP="$2"; shift 2 ;;
    --udp-seconds)       UDP_SECONDS="$2"; shift 2 ;;
    --udp-rate)          UDP_RATE="$2"; shift 2 ;;
    --no-flush-metrics)  FLUSH_TCP_METRICS=0; shift ;;
    --leg-timeout)       LEG_TIMEOUT="$2"; shift 2 ;;
    -D|--destination)    DESTINATION="$2"; shift 2 ;;
    --destinations)      DESTINATIONS="$2"; shift 2 ;;
    --target)            TARGET="$2"; shift 2 ;;
    --url)               DL_URL="$2"; shift 2 ;;
    --url-up)            UL_URL="$2"; shift 2 ;;
    --udp-host)          UDP_HOST="$2"; shift 2 ;;
    -s|--iperf-server)   IPERF_SERVER="$2"; shift 2 ;;
    --iperf-port)        IPERF_PORT="$2"; shift 2 ;;
    -o|--out)            OUT_ROOT="$2"; shift 2 ;;
    --trial)             TRIAL=1; shift ;;
    --full)              TRIAL=0; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --detach)            DETACH=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# A study is supposed to be fully described by its studies/*.conf, but the shape
# knobs used to be flag-only, so a study that wanted 25 MB transfers had to carry
# the flags in someone's shell history -- exactly the thing studies/ exists to
# prevent. These fill in AFTER flag parsing and BEFORE the profile, giving
# flag > study conf > profile.
: "${MODE:=${GVPN_MODE:-}}"
: "${CYCLES:=${GVPN_CYCLES:-}}"
: "${DURATION:=${GVPN_DURATION:-}}"
: "${DL_BYTES:=${GVPN_DL_BYTES:-}}"
: "${UL_BYTES:=${GVPN_UL_BYTES:-}}"
: "${DL_SECONDS:=${GVPN_DL_SECONDS:-}}"
: "${UL_SECONDS:=${GVPN_UL_SECONDS:-}}"
: "${REPS:=${GVPN_REPS:-}}"
: "${REP_GAP:=${GVPN_REP_GAP:-}}"
: "${UDP_SECONDS:=${GVPN_UDP_SECONDS:-}}"

apply_profile "$PROFILE"

# --trial overrides the profile rather than filling it in: the whole point is to
# be small regardless of what the study asked for. Deliberately NOT a profile of
# its own, so the arms, exits and load source stay exactly as the study declares.
if [ "$TRIAL" = 1 ]; then
  CYCLES=1; DURATION=""; REPS=1; REP_GAP=5; UDP_SECONDS=0
  MODE=bytes; DL_BYTES=5M; UL_BYTES=5M
  COOLDOWN=10
  LEG_TIMEOUT="${LEG_TIMEOUT:-90}"
fi

: "${REPS:=1}"; : "${REP_GAP:=20}"; : "${UDP_SECONDS:=0}"

case "$MODE" in
  bytes) [ -n "$DL_BYTES" ] || DL_BYTES=25M; [ -n "$UL_BYTES" ] || UL_BYTES=25M ;;
  time)  [ -n "$DL_SECONDS" ] || DL_SECONDS=60; [ -n "$UL_SECONDS" ] || UL_SECONDS=30 ;;
  *) echo "--mode must be bytes or time (got '${MODE:-}')" >&2; exit 2 ;;
esac

REP_GAP_S=$(parse_duration "$REP_GAP") || exit 2

if [ "$MODE" = bytes ]; then
  DL_B=$(parse_bytes "$DL_BYTES") || exit 2
  UL_B=$(parse_bytes "$UL_BYTES") || exit 2
  DL_EST=$(awk -v b="$DL_B" -v m="$ASSUME_MBPS" 'BEGIN{printf "%d",(b*8)/(m*1000000)+1}')
  UL_EST=$(awk -v b="$UL_B" -v m="$ASSUME_MBPS" 'BEGIN{printf "%d",(b*8)/(m*1000000)+1}')
else
  DL_EST="$DL_SECONDS"; UL_EST="$UL_SECONDS"
fi
if [ -z "$LEG_TIMEOUT" ]; then
  LEG_TIMEOUT=$(( (DL_EST > UL_EST ? DL_EST : UL_EST) * 3 ))
  [ "$LEG_TIMEOUT" -lt 120 ] && LEG_TIMEOUT=120
fi

REP_EST=$(( DL_EST + 5 + UL_EST + 5 + UDP_SECONDS ))
SESSION_EST=$(( CONNECT_EST + REPS * REP_EST + (REPS - 1) * REP_GAP_S + 15 + COOLDOWN ))

# ----------------------------------------------------------------- helpers --

now()   { date +%s; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()   { printf '%s  %s\n' "$(stamp)" "$*" | tee -a "$RUN_LOG"; }

detached() {
  if command -v setsid >/dev/null 2>&1; then setsid nohup "$@" >/dev/null 2>&1 </dev/null &
  else nohup "$@" >/dev/null 2>&1 </dev/null & fi
}

run_timeout() {
  local secs="$1"; shift
  "$@" </dev/null & local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local killer=$! rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  return $rc
}

ctl() { run_timeout "$CTL_TIMEOUT" "$CTL" "$@"; }

status_plain()    { ctl -o plain status 2>/dev/null; }
is_ready()        { status_plain | head -1 | grep -q '^Ready'; }
is_connected_to() { status_plain | grep -q "^Connected to $1 "; }
conn_line()       { status_plain | grep -E '^(Connected to|Waiting to connect to|Connecting to|Reconnecting to|Disconnecting from) ' | head -1; }
is_idle()         { [ -z "$(conn_line)" ]; }
list_destinations() { status_plain | sed -n 's/^\(.*\) (Exit: 0x[0-9a-fA-F]\{40\},.*/\1/p'; }
funding_address() {
  ctl -o json status 2>/dev/null \
    | grep -o '"node_address"[[:space:]]*:[[:space:]]*"0x[0-9a-fA-F]\{40\}"' \
    | head -1 | grep -o '0x[0-9a-fA-F]\{40\}'
}
service_log_file() { ctl -o plain info 2>/dev/null | sed -n 's/.*[Ll]og [Ff]ile[^:]*: *//p' | head -1; }

wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$(( $(now) + timeout ))
  while [ "$(now)" -lt "$deadline" ]; do
    "$@" && return 0
    sleep 3
  done
  log "TIMEOUT after ${timeout}s waiting for: $desc"
  return 1
}

# --------------------------------------------------------- dead-man switch --

dm_arm() { echo $(( $(now) + $1 + DEADMAN_MARGIN )) > "$DEADLINE_FILE.tmp" && mv "$DEADLINE_FILE.tmp" "$DEADLINE_FILE"; }

dm_start() {
  cat > "$WATCHDOG" <<EOF
#!/usr/bin/env bash
CTL="$CTL"
DEADLINE_FILE="$DEADLINE_FILE"
HARD=\$(( $(now) + $DEADMAN_HARD ))
while :; do
  sleep 5
  NOW=\$(date +%s)
  DL=\$(cat "\$DEADLINE_FILE" 2>/dev/null)
  case "\$DL" in ''|*[!0-9]*) DL=0 ;; esac
  if [ "\$NOW" -ge "\$DL" ] || [ "\$NOW" -ge "\$HARD" ]; then
    REASON=deadline; [ "\$NOW" -ge "\$HARD" ] && REASON=hard-cap
    echo "\$(date -u +%Y-%m-%dT%H:%M:%SZ) DEAD-MAN SWITCH FIRED (\$REASON)" >> "$DEADMAN_LOG"
    "\$CTL" disconnect  >> "$DEADMAN_LOG" 2>&1
    sleep 5
    "\$CTL" stop-client >> "$DEADMAN_LOG" 2>&1
    exit 0
  fi
done
EOF
  chmod +x "$WATCHDOG"
  dm_arm "$SERVICE_TIMEOUT"
  detached "$WATCHDOG"
  WATCHDOG_PID=$!
  log "dead-man switch armed (pid $WATCHDOG_PID, hard cap $(human_secs "$DEADMAN_HARD"))"
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  log "cleanup: disconnecting"
  ctl disconnect  >/dev/null 2>&1
  ctl stop-client >/dev/null 2>&1
  # Leave the node on its network config, not on whichever arm ran last.
  gvpn_restore_original && gvpn_service_restart >/dev/null 2>&1 \
    && log "cleanup: network config restored" || log "cleanup: could not restore the network config"
  echo 0 > "$DEADLINE_FILE" 2>/dev/null
  sleep 8
  kill "$WATCHDOG_PID" 2>/dev/null
  # The analyser reports the run window; a soak that died at hour 6 of 48 should
  # say so on the report rather than in someone's memory.
  printf '{"finished":"%s","exit":%s}\n' "$(stamp)" "$rc" \
    > "$RUN_DIR/finished.json" 2>/dev/null
  # Release the deploy hold. Only if it still points at THIS run -- a stale lock
  # from a crashed run is the user's to clear, and silently stealing it would let
  # two benches fight over one service.
  [ "$(readlink "$GVPN_RUN_LOCK" 2>/dev/null)" = "$RUN_DIR" ] && rm -f "$GVPN_RUN_LOCK"
  log "run finished (exit $rc); results in $RUN_DIR"
  exit $rc
}

# ------------------------------------------------------- service / configs --

# An arm is one complete config.toml (planner knobs in [connection.path_planner]).
# Installing it re-points the config.toml symlink; see lib/common.sh.
apply_arm_config() {  # apply_arm_config ARM_DIR
  local arm_dir="$1"
  ctl stop-client >/dev/null 2>&1
  rm -f $LEGACY_ARM_FILES
  gvpn_install_arm "$arm_dir/config.toml" >>"$RUN_LOG" 2>&1 || return 1
  if ! gvpn_service_restart; then
    log "  service did not start with this arm: $(gvpn_service_why | head -1)"
    gvpn_service_why | tail -n +2 | tee -a "$RUN_LOG" >/dev/null
    gvpn_restore_original && gvpn_service_restart >/dev/null 2>&1 || true
    return 1
  fi
  wait_for "$SERVICE_TIMEOUT" "service socket after config swap" \
           bash -c "$CTL ping >/dev/null 2>&1"
}

detect_identity_dir() {
  if [ -n "${GVPN_IDENTITY_DIR:-}" ]; then echo "$GVPN_IDENTITY_DIR"; return; fi
  local d
  for d in /var/lib/gnosisvpn/.config "$HOME/.config/gnosisvpn"; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
  echo ""
}


# ---------------------------------------------------------- session sampling --

start_samplers() {  # start_samplers SESSION_DIR
  local d="$1"
  ( while :; do
      printf '{"t":"%s","payload":' "$(stamp)" >> "$d/nerd-stats.ndjson"
      "$CTL" -o json nerd-stats 2>/dev/null | tr -d '\n' >> "$d/nerd-stats.ndjson"
      printf '}\n' >> "$d/nerd-stats.ndjson"
      sleep "$NERD_INTERVAL"
    done ) & SAMPLER_NERD=$!
  ( while :; do
      printf '# SAMPLE %s\n' "$(stamp)" >> "$d/telemetry.prom"
      "$CTL" telemetry 2>/dev/null >> "$d/telemetry.prom"
      sleep "$TELEMETRY_INTERVAL"
    done ) & SAMPLER_TELE=$!
  ping -i "$PING_INTERVAL" "$PING_TARGET" > "$d/ping.txt" 2>&1 & SAMPLER_PING=$!
}

stop_samplers() {
  kill "$SAMPLER_NERD" "$SAMPLER_TELE" 2>/dev/null
  # ping only prints its statistics block on SIGINT -- SIGTERM kills it silently
  # and the loss/jitter numbers for the whole session are lost.
  kill -INT "$SAMPLER_PING" 2>/dev/null
  sleep 1
  kill "$SAMPLER_PING" 2>/dev/null
  wait "$SAMPLER_NERD" "$SAMPLER_TELE" "$SAMPLER_PING" 2>/dev/null
}

# Per-rep telemetry marker, so the analyser can attribute frame discards to the
# rep they happened in rather than to the session as a whole.
mark_telemetry() {  # mark_telemetry SESSION_DIR LABEL
  printf '# MARK %s %s\n' "$(stamp)" "$2" >> "$1/telemetry.prom"
}

# Download via curl, emitting the same JSON shape iperf3 --interval 1 produces.
# The per-second series comes from stat()ing the output file once a second, which
# is a byte counter just like iperf3's -- so the analyser reads both identically
# and nothing downstream needs a special case for "no iperf3 server".
curl_leg() {  # curl_leg OUTFILE
  local out="$1" url="$DL_URL" extra=() tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/gvpn-dl.XXXXXX")

  if [ "$MODE" = bytes ]; then
    case "$url" in
      *"{bytes}"*) url="${url//\{bytes\}/$DL_B}" ;;
      # No placeholder: ask for the first N bytes instead. Needs a server that
      # honours Range; if it does not, the leg simply pulls the whole file.
      *) extra+=(-r "0-$(( DL_B - 1 ))") ;;
    esac
  else
    case "$url" in *"{bytes}"*) url="${url//\{bytes\}/2000000000}" ;; esac
    extra+=(--max-time "$DL_SECONDS")
  fi

  local t0 t1
  t0=$(date +%s.%N)
  curl -sS --fail-with-body -o "$tmp" "${extra[@]}" "$url" 2>"${out%.json}.err" &
  local cpid=$! prev=0 cur=0 waited=0 enough=0
  : > "${out%.json}.samples"
  while kill -0 "$cpid" 2>/dev/null && [ "$waited" -lt "$LEG_TIMEOUT" ]; do
    sleep 1
    cur=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
    echo $(( cur - prev )) >> "${out%.json}.samples"
    prev=$cur
    waited=$(( waited + 1 ))
    # Enforce the volume here rather than trusting the server. Not every endpoint
    # honours a Range request -- a plain file server ignores it and hands over the
    # whole file, which would silently make bytes mode measure the wrong amount.
    if [ "$MODE" = bytes ] && [ "$cur" -ge "$DL_B" ]; then enough=1; break; fi
  done
  if kill -0 "$cpid" 2>/dev/null; then
    kill -TERM "$cpid" 2>/dev/null; sleep 2; kill -KILL "$cpid" 2>/dev/null
    # Reaching the byte target is a completed leg; running out of time is not.
    [ "$enough" = 1 ] || echo "leg-timeout" > "${out%.json}.timeout"
  fi
  wait "$cpid" 2>/dev/null || true
  t1=$(date +%s.%N)
  local got; got=$(stat -c %s "$tmp" 2>/dev/null || echo 0)
  # Never report more than was asked for, so completion time and volume agree.
  [ "$MODE" = bytes ] && [ "$got" -gt "$DL_B" ] && got="$DL_B"
  rm -f "$tmp"

  python3 - "$out" "${out%.json}.samples" "$got" "$t0" "$t1" <<'PYEOF'
import json, sys
out, samples, got, t0, t1 = sys.argv[1:6]
iv = []
try:
    for line in open(samples):
        s = line.strip()
        if s.lstrip("-").isdigit():
            iv.append({"sum": {"bits_per_second": max(0, int(s)) * 8.0}})
except OSError:
    pass
json.dump({"intervals": iv,
           "end": {"sum_received": {"bytes": int(got),
                                    "seconds": max(0.001, float(t1) - float(t0))}}},
          open(out, "w"))
PYEOF
  return 0
}

# Optional upload leg in url mode. One interval only -- a POST gives no usable
# per-second progress, and the floors this study is about are on download anyway.
curl_up_leg() {  # curl_up_leg OUTFILE
  local out="$1" tmp
  [ -n "$UL_URL" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/gvpn-ul.XXXXXX")
  head -c "$UL_B" /dev/zero > "$tmp" 2>/dev/null
  local res
  res=$(run_timeout "$LEG_TIMEOUT" curl -sS -o /dev/null -X POST \
          --data-binary "@$tmp" -w '%{size_upload} %{time_total}' "$UL_URL" \
          2>"${out%.json}.err") || echo "leg-timeout" > "${out%.json}.timeout"
  rm -f "$tmp"
  python3 - "$out" "${res:-0 0}" <<'PYEOF'
import json, sys
out = sys.argv[1]
parts = (sys.argv[2] if len(sys.argv) > 2 else "0 0").split()
b = float(parts[0]) if parts else 0.0
s = float(parts[1]) if len(parts) > 1 else 0.0
iv = [{"sum": {"bits_per_second": (b * 8.0 / s) if s > 0 else 0.0}}]
json.dump({"intervals": iv,
           "end": {"sum_sent": {"bytes": int(b), "seconds": max(0.001, s)}}},
          open(out, "w"))
PYEOF
  return 0
}

# One place decides where the bytes come from, so run_reps stays load-agnostic.
transfer_leg() {  # transfer_leg OUTFILE down|up
  if [ "$TARGET" = url ]; then
    [ "$2" = up ] && curl_up_leg "$1" || curl_leg "$1"
  else
    iperf_leg "$1" "$2"
  fi
}

iperf_leg() {  # iperf_leg OUTFILE down|up
  local out="$1" dir="$2" rev="" amount=()
  [ "$dir" = down ] && rev="-R"
  if [ "$MODE" = bytes ]; then
    [ "$dir" = down ] && amount=(-n "$DL_BYTES") || amount=(-n "$UL_BYTES")
  else
    [ "$dir" = down ] && amount=(-t "$DL_SECONDS") || amount=(-t "$UL_SECONDS")
  fi
  run_timeout "$LEG_TIMEOUT" \
    iperf3 -c "$IPERF_SERVER" -p "$IPERF_PORT" $rev "${amount[@]}" -i 1 --json \
    > "$out" 2>"${out%.json}.err"
  local rc=$?
  # A leg killed by the cap is a data point, not a crash: in bytes mode it means
  # the session was too slow to move the volume in 3x the expected time.
  [ $rc -ne 0 ] && echo "$rc" > "${out%.json}.timeout"
  return 0
}

udp_leg() {  # udp_leg OUTFILE
  [ "${UDP_SECONDS:-0}" -gt 0 ] || return 0
  # In url mode there is no iperf3 server unless one is named explicitly. A public
  # iperf3 server works here: its absolute numbers are unreliable under shared
  # load, but with round-robin interleaving that noise hits every arm equally.
  local host="${UDP_HOST:-$IPERF_SERVER}"
  [ -n "$host" ] || return 0
  # UDP download: no congestion controller in the path, so the jitter and loss
  # iperf3 reports are the path's own, not TCP's reaction to them.
  run_timeout $(( UDP_SECONDS + 45 )) \
    iperf3 -c "$host" -p "$IPERF_PORT" -R -u -b "$UDP_RATE" \
           -t "$UDP_SECONDS" -i 1 --json \
    > "$1" 2>"${1%.json}.err"
  return 0
}

log_offset() { [ -n "$SVC_LOG" ] && [ -r "$SVC_LOG" ] && wc -c < "$SVC_LOG" | tr -d ' ' || echo 0; }
log_slice()  { [ -n "$SVC_LOG" ] && [ -r "$SVC_LOG" ] && tail -c "+$(( $1 + 1 ))" "$SVC_LOG" > "$2" 2>/dev/null; }

# ------------------------------------------------------------------ setup --

command -v "$CTL" >/dev/null 2>&1 || { echo "$CTL not found in PATH" >&2; exit 1; }

case "$TARGET" in
  iperf3)
    command -v iperf3 >/dev/null 2>&1 || { echo "iperf3 not found in PATH" >&2; exit 1; }
    [ -n "$IPERF_SERVER" ] || {
      echo "--iperf-server is required with --target iperf3" >&2
      echo "(or use --target url to pull from a public endpoint instead)" >&2
      usage >&2; exit 2; }
    ;;
  url)
    command -v curl    >/dev/null 2>&1 || { echo "curl not found in PATH" >&2; exit 1; }
    command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 1; }
    [ -n "$DL_URL" ] || { echo "--url is required with --target url" >&2; exit 2; }
    if [ "${UDP_SECONDS:-0}" -gt 0 ] && [ -z "$UDP_HOST$IPERF_SERVER" ]; then
      # Not fatal: the session telemetry and the concurrent ping both measure
      # loss and jitter without any far end, and they measure the HOPR leg
      # rather than the whole internet path.
      echo "note: no --udp-host, so the iperf3 UDP leg is skipped."
      echo "      loss/jitter still come from ping.txt and the session telemetry."
      UDP_SECONDS=0
    fi
    ;;
  *) echo "--target must be iperf3 or url (got '$TARGET')" >&2; exit 2 ;;
esac

# curl_up_leg needs a size even in time mode.
[ -n "${UL_B:-}" ] || UL_B=$(parse_bytes "${UL_BYTES:-25M}")
[ -d "$ARMS_DIR" ] || { echo "arms dir not found: $ARMS_DIR" >&2; exit 1; }

[ -n "$ARMS" ] || ARMS="$(cd "$ARMS_DIR" && ls -d */ 2>/dev/null | tr -d '/' | tr '\n' ' ')"
[ -n "$ARMS" ] || { echo "no arms found in $ARMS_DIR" >&2; exit 1; }
ARM_COUNT=$(printf '%s\n' $ARMS | grep -c .)

# One list drives the loop whether the user gave one exit or several.
[ -n "$DESTINATIONS" ] || DESTINATIONS="$DESTINATION"
DEST_COUNT=$(printf '%s\n' $DESTINATIONS | grep -c . || echo 1)
[ "$DEST_COUNT" -lt 1 ] && DEST_COUNT=1

CYCLE_EST=$(( SESSION_EST * ARM_COUNT * DEST_COUNT ))
if [ -n "$DURATION" ]; then
  BUDGET=$(parse_duration "$DURATION") || exit 2
  [ -n "$CYCLES" ] || CYCLES=$(( BUDGET / CYCLE_EST + 1 ))
else
  BUDGET=""
  [ -n "$CYCLES" ] || CYCLES=3
fi
TOTAL_EST=$(( CYCLE_EST * CYCLES ))
[ -n "$BUDGET" ] && [ "$TOTAL_EST" -gt "$BUDGET" ] && TOTAL_EST="$BUDGET"
[ -n "$DEADMAN_HARD" ] || DEADMAN_HARD=$(( TOTAL_EST + 3600 ))

describe_schedule() {
  if [ "$TRIAL" = 1 ]; then
    echo "MODE:         *** TRIAL *** -- a rehearsal of this study, not a result."
    echo "              Same arms, same exits, 1 cycle x 1 rep x 5 MB."
  fi
  echo "profile:      $PROFILE$([ "$TRIAL" = 1 ] && echo "  (overridden by --trial)")"
  echo "arms:         $(echo $ARMS) ($ARM_COUNT)"
  echo "exits:        ${DESTINATIONS:-<first reported>} ($DEST_COUNT)"
  if [ "$MODE" = bytes ]; then
    echo "mode:         bytes -- down $DL_BYTES, up $UL_BYTES (estimates assume ~${ASSUME_MBPS} Mbit/s)"
  else
    echo "mode:         time -- down ${DL_SECONDS}s, up ${UL_SECONDS}s"
  fi
  echo "reps:         $REPS per session, ${REP_GAP} apart, tcp_metrics flush=$FLUSH_TCP_METRICS"
  [ "${UDP_SECONDS:-0}" -gt 0 ] && echo "udp probe:    ${UDP_SECONDS}s at $UDP_RATE (jitter + datagram loss)"
  if [ "$TARGET" = url ]; then
    echo "load source:  url -- ${DL_URL}"
    [ -n "$UL_URL" ] && echo "              upload: $UL_URL" || echo "              (download only; no upload leg)"
  else
    echo "load source:  iperf3 $IPERF_SERVER:$IPERF_PORT"
  fi
  echo "leg timeout:  ${LEG_TIMEOUT}s"
  echo "per session:  ~${SESSION_EST}s    per cycle: ~${CYCLE_EST}s"
  echo "cycles:       $CYCLES => $CYCLES sessions per arm PER EXIT, $(( CYCLES * ARM_COUNT * DEST_COUNT * REPS )) transfers total"
  [ -n "$BUDGET" ] && echo "time budget:  $DURATION ($(human_secs "$BUDGET")) -- stops after the last whole cycle that fits"
  echo "estimated:    $(human_secs "$TOTAL_EST")"
  echo "dead-man cap: $(human_secs "$DEADMAN_HARD")"
  if [ "$CYCLES" -lt 20 ]; then
    echo
    echo "NOTE: $CYCLES sessions per arm is a signal check, not a result. Tail"
    echo "      statistics (p10, floor rate) need >=30 per arm -- use --profile"
    echo "      standard or soak for anything that goes in the report."
  fi
}

# No shipped arm re-onboards, and none should: a new identity belongs to the
# NODE, not to the arm, so every later session of every other arm would run on
# it. Retargeting channels is an ordinary on-chain close (tools/close-channels.py)
# and needs no new identity. The marker is still honoured as a refusal, because
# a hand-made arm carrying it would otherwise destroy a funded identity.
for _a in $ARMS; do
  if [ -f "$ARMS_DIR/$_a/needs_fresh_identity" ]; then
    cat >&2 <<EOF
REFUSING TO RUN: arm '$_a' is marked needs_fresh_identity.

Re-onboarding is not supported. It replaces the node's identity, which is
node-global, so it contaminates every other arm in the run -- and it is not
needed: close the channels you do not want instead.

  sudo -E ./tools/close-channels.py --keep 0xRELAY --send

Remove $ARMS_DIR/$_a/needs_fresh_identity once the arm no longer expects it.
EOF
    exit 2
  fi
done

# An arm carrying a PREREQUISITE has been put into a state by hand -- for
# pin-cfg, a channel set trimmed to one relay. That state belongs to the NODE,
# not to the arm, so every other arm in the run inherits it: while you are down
# to one channel, 'auto' is not auto. The operator did the manual step
# deliberately, so this warns rather than refuses.
PREREQ_ARMS=""
for _a in $ARMS; do
  [ -f "$ARMS_DIR/$_a/PREREQUISITE" ] && PREREQ_ARMS="$PREREQ_ARMS $_a"
done
PREREQ_ARMS="${PREREQ_ARMS# }"
if [ -n "$PREREQ_ARMS" ] && [ "$ARM_COUNT" -gt 1 ]; then
  cat >&2 <<EOF

WARNING: $PREREQ_ARMS needed a manual change to this node's channel set.

That change is node-global. Every other arm in this run measures a node in that
state, so the control is not the control you would get on an untouched node.
Prefer a separate study with its own baseline. Continuing in 10s.

EOF
  sleep 10
fi

[ "$DRY_RUN" = 1 ] && { describe_schedule; exit 0; }

RUN_ID="${GVPN_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)}"
RUN_DIR="$OUT_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR" || exit 1

# Announce the run. The deploy hook refuses to replace the worktree while this
# exists: push-to-checkout rewrites script files in place, and bash reads a
# script incrementally as it runs, so a push mid-soak can corrupt the running
# bench or silently swap the analysis under a study that is already half done.
if [ -e "$GVPN_RUN_LOCK" ] && [ "${GVPN_RUN_ID:-}" = "" ]; then
  echo "a run is already in progress: $(readlink "$GVPN_RUN_LOCK" 2>/dev/null)" >&2
  echo "finish or stop it first, or remove $GVPN_RUN_LOCK if it is stale." >&2
  exit 1
fi
ln -sfn "$RUN_DIR" "$GVPN_RUN_LOCK" 2>/dev/null || true
RUN_LOG="$RUN_DIR/run.log"
DEADMAN_LOG="$RUN_DIR/deadman.log"
WATCHDOG="$RUN_DIR/watchdog.sh"
DEADLINE_FILE="$RUN_DIR/deadline"
SUMMARY="$RUN_DIR/summary.csv"
touch "$CODES_LEDGER" 2>/dev/null || true
: > "$RUN_LOG"; touch "$USED_CODES" 2>/dev/null

if [ "$DETACH" = 1 ]; then
  export GVPN_RUN_ID="$RUN_ID"
  command -v setsid >/dev/null 2>&1 && SETSID=setsid || SETSID=""
  nohup $SETSID "$0" --profile custom ${TRIAL:+$([ "$TRIAL" = 1 ] && echo --trial)} \
        --arms-dir "$ARMS_DIR" -a "$ARMS" -n "$CYCLES" \
        --mode "$MODE" --leg-timeout "$LEG_TIMEOUT" --reps "$REPS" --rep-gap "$REP_GAP" \
        --udp-seconds "$UDP_SECONDS" --udp-rate "$UDP_RATE" \
        ${DURATION:+--duration "$DURATION"} \
        ${DL_BYTES:+--dl-bytes "$DL_BYTES"} ${UL_BYTES:+--ul-bytes "$UL_BYTES"} \
        ${DL_SECONDS:+--dl-seconds "$DL_SECONDS"} ${UL_SECONDS:+--ul-seconds "$UL_SECONDS"} \
        --target "$TARGET" ${DL_URL:+--url "$DL_URL"} ${UL_URL:+--url-up "$UL_URL"} \
        ${UDP_HOST:+--udp-host "$UDP_HOST"} \
        ${IPERF_SERVER:+-s "$IPERF_SERVER"} --iperf-port "$IPERF_PORT" \
        -o "$OUT_ROOT" \
        ${DESTINATION:+-D "$DESTINATION"} \
        >>"$RUN_DIR/detached.log" 2>&1 </dev/null &
  echo "$RUN_DIR"; exit 0
fi

trap cleanup EXIT INT TERM
dm_start

log "gvpn-bench.sh $VERSION starting"
log "run dir:     $RUN_DIR"
describe_schedule | while IFS= read -r l; do log "$l"; done
[ "$TARGET" = iperf3 ] && log "iperf3:      $IPERF_SERVER:$IPERF_PORT"
log "local cc:    $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?') (upload sender)"
log "RUST_LOG:    $(tr '\0' '\n' < "/proc/$(systemctl show gnosisvpn -p MainPID --value)/environ" 2>/dev/null | sed -n 's/^RUST_LOG=//p') (the service's)"
log "ctl version: $($CTL -V 2>&1)"

# Provenance. Six weeks from now the only defensible answer to "what binary
# produced these numbers?" is the one the run recorded for itself, so capture it
# here rather than trusting that nothing was upgraded in between.
CLIENT_INFO="$($CTL info 2>/dev/null || true)"
CLIENT_SVC="$(printf '%s' "$CLIENT_INFO" | sed -n 's/.*client service version:[[:space:]]*\([^,]*\).*/\1/p' | head -1)"
CLIENT_PKG="$(printf '%s' "$CLIENT_INFO" | sed -n 's/.*package version:[[:space:]]*\([^,[:space:]]*\).*/\1/p' | head -1)"
[ -n "$CLIENT_PKG" ] || CLIENT_PKG="$(dpkg-query -W -f='${Version}' gnosisvpn 2>/dev/null || true)"
KIT_REV="$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null || true)"
git -C "$KIT" diff --quiet HEAD 2>/dev/null || KIT_REV="${KIT_REV:+$KIT_REV}-dirty"

# Which arms are CONFIGURED to pin (one candidate path), read from their configs
# -- the analyzer checks the pin on exactly these, whichever arm performs best.
PINNED_ARMS=""
for _a in $ARMS; do
  [ "$(python3 "$GVPN_KIT/lib/tomlmerge.py" get "$ARMS_DIR/$_a/config.toml" \
        connection.path_planner.max_cached_paths 2>/dev/null)" = 1 ] && PINNED_ARMS="$PINNED_ARMS $_a"
done
PINNED_ARMS="${PINNED_ARMS# }"

cat > "$RUN_DIR/manifest.json" <<EOF
{"version":"$VERSION","profile":"$PROFILE","trial":$([ "$TRIAL" = 1 ] && echo true || echo false),"mode":"$MODE",
 "client_service":"$CLIENT_SVC","client_package":"$CLIENT_PKG",
 "channel":"${GVPN_CHANNEL:-}","network":"${GVPN_NETWORK:-}","kit_rev":"$KIT_REV",
 "host_cc":"$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')",
 "study":"${GVPN_STUDY_NAME:-}","floor_mbps":"${GVPN_FLOOR_MBPS:-}",
 "dl_bytes":"${DL_BYTES:-}","ul_bytes":"${UL_BYTES:-}",
 "dl_seconds":"${DL_SECONDS:-}","ul_seconds":"${UL_SECONDS:-}",
 "reps":$REPS,"rep_gap_s":$REP_GAP_S,"udp_seconds":${UDP_SECONDS:-0},"udp_rate":"$UDP_RATE",
 "leg_timeout":$LEG_TIMEOUT,"cycles":$CYCLES,"duration":"${DURATION:-}",
 "arms":"$ARMS","pinned_arms":"$PINNED_ARMS","destinations":"${DESTINATIONS:-}","target":"$TARGET","dl_url":"${DL_URL:-}","ul_url":"${UL_URL:-}",
 "iperf_server":"$IPERF_SERVER","udp_host":"${UDP_HOST:-}","started":"$(stamp)"}
EOF

echo "cycle,arm,destination,session_dir,connect_seconds,reps,result" > "$SUMMARY"
SVC_LOG="$(service_log_file)"
log "service log: ${SVC_LOG:-<unknown>}"

# ------------------------------------------------------------ the main loop --

run_reps() {  # run_reps SESSION_DIR
  local d="$1" r
  for r in $(seq 1 "$REPS"); do
    local rd="$d/rep-$r"
    mkdir -p "$rd"
    mark_telemetry "$d" "rep-$r-start"

    # Kill the kernel's per-destination TCP metrics so a bad rep cannot seed the
    # next rep's initial ssthresh. Without this, reps are not independent.
    if [ "$FLUSH_TCP_METRICS" = 1 ]; then
      ip tcp_metrics flush all >/dev/null 2>&1 || true
    fi

    log "    rep $r/$REPS: download"
    echo "$(stamp)" > "$rd/t_dl_start"
    transfer_leg "$rd/iperf-down.json" down
    sleep 5

    log "    rep $r/$REPS: upload"
    echo "$(stamp)" > "$rd/t_ul_start"
    transfer_leg "$rd/iperf-up.json" up

    if [ "${UDP_SECONDS:-0}" -gt 0 ]; then
      sleep 3
      log "    rep $r/$REPS: udp probe"
      echo "$(stamp)" > "$rd/t_udp_start"
      udp_leg "$rd/iperf-udp.json"
    fi

    mark_telemetry "$d" "rep-$r-end"

    if [ "$r" -lt "$REPS" ]; then
      log "    idle ${REP_GAP} before rep $(( r + 1 )) (session stays open)"
      dm_arm $(( REP_GAP_S + 2 * LEG_TIMEOUT + 180 ))
      sleep "$REP_GAP_S"
    fi
  done
}

run_session() {  # run_session CYCLE ARM [DEST]
  local cycle="$1" arm="$2" want_dest="${3:-}"
  local arm_dir="$ARMS_DIR/$arm"
  # The exit is part of the session's identity, so a run that sweeps several
  # exits does not collide on disk and the analyser can group by (arm, exit).
  local tag="$arm"
  [ -n "$want_dest" ] && tag="${arm}__$(printf '%s' "$want_dest" | tr ' /' '__')"
  local d="$RUN_DIR/cycle-$(printf '%03d' "$cycle")/$tag"
  mkdir -p "$d"
  log "--- cycle $cycle / arm $arm${want_dest:+ / exit $want_dest} ---"

  dm_arm "$SERVICE_TIMEOUT"
  apply_arm_config "$arm_dir" || { echo "$cycle,$arm,-,$d,-,$REPS,config-failed" >> "$SUMMARY"; return 1; }

  ctl start-client "$KEEPALIVE" >>"$RUN_LOG" 2>&1
  dm_arm "$ONBOARD_TIMEOUT"
  wait_for "$ONBOARD_TIMEOUT" "node Ready" is_ready \
    || { echo "$cycle,$arm,-,$d,-,$REPS,not-ready" >> "$SUMMARY"; return 1; }

  local dest="${want_dest:-$DESTINATION}"
  [ -n "$dest" ] || dest="$(list_destinations | head -1)"
  [ -n "$dest" ] || { echo "$cycle,$arm,-,$d,-,$REPS,no-destination" >> "$SUMMARY"; return 1; }

  local off; off=$(log_offset)
  dm_arm $(( CONNECT_TIMEOUT + SESSION_EST + 180 ))
  local t0; t0=$(now)
  ctl connect "$dest" > "$d/connect.txt" 2>&1
  if ! wait_for "$CONNECT_TIMEOUT" "connection to $dest" is_connected_to "$dest"; then
    status_plain > "$d/status-connect-timeout.txt"
    log_slice "$off" "$d/gnosisvpn.log"
    echo "$cycle,$arm,$dest,$d,-,$REPS,connect-timeout" >> "$SUMMARY"
    ctl disconnect >/dev/null 2>&1
    return 1
  fi
  local connsec=$(( $(now) - t0 ))
  log "  connected in ${connsec}s"
  status_plain > "$d/status-connected.txt"
  echo "$(stamp)" > "$d/t_connected"

  start_samplers "$d"
  run_reps "$d"
  stop_samplers

  status_plain > "$d/status-after.txt"
  dm_arm "$DISCONNECT_TIMEOUT"
  ctl disconnect > "$d/disconnect.txt" 2>&1
  wait_for "$DISCONNECT_TIMEOUT" "disconnect from $dest" is_idle \
    || log "  WARNING: not idle after ${DISCONNECT_TIMEOUT}s"
  log_slice "$off" "$d/gnosisvpn.log"

  echo "$cycle,$arm,$dest,$d,$connsec,$REPS,ok" >> "$SUMMARY"
  sleep "$COOLDOWN"
}

RUN_START=$(now)
CYCLE=1
while [ "$CYCLE" -le "$CYCLES" ]; do
  # A time-budgeted run only starts a cycle it can plausibly finish, so the last
  # cycle is never half-populated -- which would skew the paired per-cycle stats.
  if [ -n "$BUDGET" ]; then
    ELAPSED=$(( $(now) - RUN_START ))
    if [ $(( ELAPSED + CYCLE_EST )) -gt "$BUDGET" ]; then
      log "time budget reached after $(( CYCLE - 1 )) cycles ($(human_secs "$ELAPSED")); stopping"
      break
    fi
  fi
  log "===== cycle $CYCLE/$CYCLES ====="
  # Arms inner, exits outer -- so every arm meets every exit within the same
  # cycle and the paired per-cycle comparison holds for each exit separately.
  if [ "$DEST_COUNT" -gt 1 ] || [ -n "$DESTINATIONS" ]; then
    for DST in $DESTINATIONS; do
      for ARM in $ARMS; do
        run_session "$CYCLE" "$ARM" "$DST" \
          || log "  arm $ARM / exit $DST failed this cycle; continuing"
      done
    done
  else
    for ARM in $ARMS; do
      run_session "$CYCLE" "$ARM" || log "  arm $ARM failed this cycle; continuing"
    done
  fi
  CYCLE=$(( CYCLE + 1 ))
done

log "===== done: $(( CYCLE - 1 )) cycles in $(human_secs $(( $(now) - RUN_START ))) ====="
log "analyse with: python3 gvpn-analyze.py $RUN_DIR"
