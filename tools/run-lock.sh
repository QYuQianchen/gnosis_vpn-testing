#!/usr/bin/env bash
# Show the run lock, or clear it if no bench holds it.
#
#   ./tools/run-lock.sh            what the lock says, and whether its bench is alive
#   ./tools/run-lock.sh --clear    remove it -- only if no gvpn-bench.sh is running
#
# The lock ($GVPN_STATE/run.lock) blocks deploys while a bench runs. A bench
# records its PID in <run>/bench.pid, so a lock whose bench died is provably
# stale. A lock from before bench.pid existed has no owner recorded; this tool
# settles that with pgrep, which a bench cannot do about itself.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

CLEAR=0
case "${1:-}" in
  --clear) CLEAR=1 ;;
  "") ;;
  -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

gvpn_lock_state
running="$(pgrep -af 'bench/gvpn-bench\.sh' || true)"
if [ "$GVPN_LOCK_STATE" = unknown ] && [ -z "$running" ]; then
  GVPN_LOCK_STATE=stale
fi

case "$GVPN_LOCK_STATE" in
  none)    echo "no run lock"; exit 0 ;;
  live)    echo "LIVE: $GVPN_LOCK_RUN is running (pid $GVPN_LOCK_PID). Not touching it."; exit 1 ;;
  unknown) echo "LIVE?: $GVPN_LOCK_RUN has no owner recorded, and a bench is running:"
           echo "$running" | sed 's/^/  /'; exit 1 ;;
  stale)   echo "STALE: $GVPN_LOCK_RUN -- its bench is not running"
           { grep -h 'KILLED' "$GVPN_LOCK_RUN/run.log" 2>/dev/null || true; } | tail -1 | sed 's/^/  /' ;;
esac

if [ "$CLEAR" = 1 ]; then
  rm -f "$GVPN_RUN_LOCK" && echo "cleared $GVPN_RUN_LOCK"
else
  echo "clear it with: $0 --clear"
fi
