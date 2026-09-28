#!/usr/bin/env bash
# ExecStopPost of a detached bench (gvpn-bench.sh --detach runs it as a systemd
# unit). Runs however the bench ended. If the bench's own cleanup did not finish
# -- SIGKILL, the OOM killer, a stop that outlasted its timeout -- this puts the
# node back on its network config, records why in run.log and finished.json,
# and releases the run lock. systemd sets SERVICE_RESULT/EXIT_CODE/EXIT_STATUS.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

RUN_DIR="${1:?usage: on-bench-exit.sh RUN_DIR}"
[ -f "$RUN_DIR/finished.json" ] && exit 0   # the bench cleaned up itself

why="${SERVICE_RESULT:-unknown} (${EXIT_CODE:-?} ${EXIT_STATUS:-?})"
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "$stamp KILLED before its cleanup: $why -- restoring the network config" >>"$RUN_DIR/run.log"

timeout 30 "${GVPN_CTL:-gnosis_vpn-ctl}" disconnect >/dev/null 2>&1
if gvpn_restore_original && gvpn_service_restart >/dev/null 2>&1; then
  echo "$stamp network config restored" >>"$RUN_DIR/run.log"
else
  echo "$stamp could NOT restore the network config: sudo ./bench/use-arm.sh --restore" >>"$RUN_DIR/run.log"
fi

printf '{"finished":"%s","exit":null,"killed":"%s"}\n' "$stamp" "$why" >"$RUN_DIR/finished.json"
[ "$(readlink "$GVPN_RUN_LOCK" 2>/dev/null)" = "$RUN_DIR" ] && rm -f "$GVPN_RUN_LOCK"
gvpn_give_back "$RUN_DIR"
exit 0
