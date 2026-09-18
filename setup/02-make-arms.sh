#!/usr/bin/env bash
#
# 02-make-arms.sh -- generate the experiment's arm definitions.
#
#   sudo ./02-make-arms.sh --out ./arms
#   sudo ./02-make-arms.sh --out ./arms --pin-relay 0xRELAY_A --pin-relay 0xRELAY_B
#
# An "arm" is one routing configuration under test. Each arm is a directory:
#
#   arms/<name>/config.toml   -> /etc/gnosisvpn/config.toml
#   arms/<name>/hopr.yaml     -> /etc/gnosisvpn/hopr-arm.yaml   (optional)
#   arms/<name>/env           -> extra systemd Environment= lines (optional)
#   arms/<name>/needs_fresh_identity  (optional marker)
#   arms/<name>/README        what this arm tests
#
# THE KEY LEVER, and it needs no recompile:
#
#   The service honours GNOSISVPN_HOPR_CONFIG_PATH. Setting it switches the
#   worker from a generated hopr-lib config to a file you supply, which exposes
#   the whole HoprLibConfig -- including protocol.path_planner. That is where
#   the path draw lives:
#
#     max_cached_paths          candidates the selector may return per query
#     return_path_exploration   fraction of return draws made uniformly at random
#     return_path_weight_temper exponent flattening the return-path weights
#     min_paths_anonymity_floor candidate count below which no pruning happens
#     latency_halflife          how hard latency is weighted
#
#   max_cached_paths = 1 collapses the weighted collection to a single entry, so
#   forward AND return resolve to one path, per packet, deterministically. That is
#   a genuine pin of both legs -- without patching hopr-lib and without the
#   channel churn that allowlist-based pinning costs.
#
#   Two caveats this script handles:
#     * manual mode does NOT inject the safe/module addresses, so they are read
#       from the node's own gnosisvpn-hopr.safe and written into the YAML;
#     * generated mode also tightens the probe intervals to 3s for edge clients,
#       so the YAML replicates that or the node warms up far more slowly.
#
set -euo pipefail

OUT="./arms"
PROD_CONFIG="${GVPN_PROD_CONFIG:-/etc/gnosisvpn/config.toml}"
SAFE_FILE="${GVPN_SAFE_FILE:-/var/lib/gnosisvpn/.config/gnosisvpn-hopr.safe}"
HOPR_YAML_DEST="${GVPN_HOPR_YAML_DEST:-/etc/gnosisvpn/hopr-arm.yaml}"
DESTINATION_ONLY=""
PIN_RELAYS=()
MIN_ACK_RATE="${GVPN_MIN_ACK_RATE:-0.1}"

usage() {
  cat <<EOF
02-make-arms.sh -- generate arm definitions for the #8408 benchmark

Usage: sudo $0 [--out DIR] [--pin-relay 0x... ]...

  --out DIR             where to write the arms (default: $OUT)
  --pin-relay ADDR      add a channel-allowlist arm pinned to this relay.
                        Repeatable. These arms need a fresh identity each
                        (the allowlist only applies while channels are opened),
                        so budget one faucet code per relay.
  --destination ID      keep only this destination in the arm configs
                        (recommended: one exit, so the exit is not a variable)
  --prod-config PATH    source config to derive from (default: $PROD_CONFIG)
  --safe-file PATH      node safe file to read addresses from (default: $SAFE_FILE)
  -h, --help

Arms produced:
  auto           stock config, 1 hop, automatic path finding        [control]
  pin-planner    max_cached_paths=1, exploration=0  -> one path, both legs
  no-explore     exploration=0 only                 -> isolates the 10% blind draws
  narrow         max_cached_paths=3, temper=1.0     -> less spread, some diversity
  zero-hop       hops=0                             -> no relay at all [upper bound]
  pin-cfg-<n>    channel allowlist per --pin-relay  -> forward leg only

Run AFTER the node has onboarded once and reached Ready, so the safe file exists.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --pin-relay)    PIN_RELAYS+=("$2"); shift 2 ;;
    --destination)  DESTINATION_ONLY="$2"; shift 2 ;;
    --prod-config)  PROD_CONFIG="$2"; shift 2 ;;
    --safe-file)    SAFE_FILE="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -r "$PROD_CONFIG" ] || { echo "cannot read $PROD_CONFIG" >&2; exit 1; }

SAFE_ADDR=""; MODULE_ADDR=""
if [ -r "$SAFE_FILE" ]; then
  SAFE_ADDR=$(sed -n 's/^ *safe_address: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p'   "$SAFE_FILE" | head -1)
  MODULE_ADDR=$(sed -n 's/^ *module_address: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "$SAFE_FILE" | head -1)
fi
if [ -z "$SAFE_ADDR" ] || [ -z "$MODULE_ADDR" ]; then
  cat >&2 <<EOF
WARNING: could not read safe/module addresses from $SAFE_FILE

The planner arms (pin-planner, no-explore, narrow) need them, because a manual
hopr-lib config does not get them injected. Onboard the node first:

    gnosis_vpn-ctl start-client 30m
    gnosis_vpn-ctl status          # wait for "Ready"

then re-run this script. The planner arms are being written with placeholders
and WILL FAIL to start until you fill them in.
EOF
  SAFE_ADDR="0xFILL_ME_IN"; MODULE_ADDR="0xFILL_ME_IN"
fi

mkdir -p "$OUT"

# ------------------------------------------------------------------ helpers --

# Copy the production config, optionally reducing it to a single destination and
# forcing an explicit hop count. Keeping one exit is deliberate: with eight in the
# file, "which exit" becomes an uncontrolled variable across arms.
make_config() {  # make_config OUTFILE HOPS
  local out="$1" hops="$2"
  python3 - "$PROD_CONFIG" "$out" "$hops" "${DESTINATION_ONLY:-}" <<'PY'
import re, sys
src, out, hops, only = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()

lines, cur, blocks, head = text.splitlines(), None, {}, []
for ln in lines:
    m = re.match(r'\s*\[destinations\.(.+?)\]\s*$', ln)
    if m:
        cur = m.group(1).strip().strip('"')
        blocks[cur] = [ln]
        continue
    if cur is not None:
        if re.match(r'\s*\[', ln):          # a new, non-destination table
            cur = None
            head.append(ln)
        else:
            blocks[cur].append(ln)
    else:
        head.append(ln)

keep = [only] if only else list(blocks)
missing = [k for k in keep if k not in blocks]
if missing:
    sys.exit(f"destination(s) not found in {src}: {missing}. Have: {list(blocks)}")

body = []
for name in keep:
    for ln in blocks[name]:
        if re.match(r'\s*path\s*=', ln):     # replaced below
            continue
        body.append(ln.rstrip())
    body.append(f"path    = {{ hops = {hops} }}")
    body.append("")

# head keeps version=, [connection...] and [strategy...] from the source config
open(out, "w").write("\n".join([l.rstrip() for l in head if l.strip()] + [""] + body) + "\n")
PY
}

# A minimal hopr-lib config. Every field of HoprLibConfig has a serde default, so
# only the deviations need stating -- but the struct is deny_unknown_fields, so a
# typo fails loudly at service start rather than being silently ignored. Good.
make_hopr_yaml() {  # make_hopr_yaml OUTFILE PLANNER_BODY
  local out="$1"; shift
  cat > "$out" <<EOF
# Manual hopr-lib config for one benchmark arm.
# Selected by GNOSISVPN_HOPR_CONFIG_PATH; switches the worker out of generated
# mode, which is why safe_module has to be stated explicitly here.
safe_module:
  safe_address: "$SAFE_ADDR"
  module_address: "$MODULE_ADDR"

protocol:
  # Replicates what generated mode does for edge clients: probe aggressively at
  # startup so relay observations exist before the first health check fires.
  probe:
    timeout: 3s
    interval: 3s
    recheck_threshold: 3s
  path_planner:
$1
EOF
}

arm() {  # arm NAME README_TEXT
  mkdir -p "$OUT/$1"
  printf '%s\n' "$2" > "$OUT/$1/README"
}

use_hopr_yaml() {  # use_hopr_yaml ARM
  cat > "$OUT/$1/env" <<EOF
GNOSISVPN_HOPR_CONFIG_PATH=$HOPR_YAML_DEST
EOF
}

# -------------------------------------------------------------------- arms --

echo "writing arms to $OUT"

# --- control -----------------------------------------------------------------
arm auto "\
CONTROL. Stock production configuration, 1 intermediate hop, automatic path
finding with the shipped edge-client planner settings:
  max_cached_paths 50, min_paths_anonymity_floor 0 (pruning off),
  return_path_weight_temper 0.5, return_path_exploration 0.1.
Every other arm is read as a difference from this one."
make_config "$OUT/auto/config.toml" 1

# --- the pin -----------------------------------------------------------------
arm pin-planner "\
PINNED, BOTH LEGS, NO RECOMPILE. max_cached_paths = 1 collapses the weighted
candidate collection to a single validated path, so every packet's forward route
and every SURB's return route resolve to the same path. exploration = 0 removes
the uniform-random draws on top.
This is the arm that tests whether multipath striping is the floor mechanism:
if the throughput DISTRIBUTION tightens here -- even at the same or slightly
lower median -- striping is implicated."
make_config "$OUT/pin-planner/config.toml" 1
make_hopr_yaml "$OUT/pin-planner/hopr.yaml" "\
    max_cached_paths: 1
    min_paths_anonymity_floor: 0
    return_path_exploration: 0.0
    return_path_weight_temper: 1.0
    min_ack_rate: $MIN_ACK_RATE"
use_hopr_yaml pin-planner

# --- one variable at a time --------------------------------------------------
arm no-explore "\
ONE VARIABLE. Identical to auto except return_path_exploration = 0. Keeps full
relay diversity but stops the 10% of return draws that ignore quality entirely.
If auto and pin-planner differ but auto and no-explore do not, the exploration
term is not the problem and the spread across GOOD relays is."
make_config "$OUT/no-explore/config.toml" 1
make_hopr_yaml "$OUT/no-explore/hopr.yaml" "\
    max_cached_paths: 50
    min_paths_anonymity_floor: 0
    return_path_exploration: 0.0
    return_path_weight_temper: 0.5
    min_ack_rate: $MIN_ACK_RATE"
use_hopr_yaml no-explore

arm narrow "\
MIDDLE GROUND. Three candidates instead of fifty, weights untempered so the best
one dominates, no blind exploration. If this recovers most of pin-planner's
benefit, there is a shippable setting that keeps some relay diversity -- which
matters, because diversity is a privacy and resilience property, not just cost."
make_config "$OUT/narrow/config.toml" 1
make_hopr_yaml "$OUT/narrow/hopr.yaml" "\
    max_cached_paths: 3
    min_paths_anonymity_floor: 0
    return_path_exploration: 0.0
    return_path_weight_temper: 1.0
    min_ack_rate: $MIN_ACK_RATE"
use_hopr_yaml narrow

# --- upper bound -------------------------------------------------------------
arm zero-hop "\
UPPER BOUND, NOT A PRODUCT CONFIGURATION. No relay in the path at all, so
whatever throughput and variance remains belongs to the entry, the exit,
WireGuard and the session layer. Requires the service to run with
--allow-insecure (00-vm-setup.sh --allow-insecure), and exposes this client's
IP to the exit. Throwaway identity only."
make_config "$OUT/zero-hop/config.toml" 0
echo "--allow-insecure" > "$OUT/zero-hop/flags"

# --- allowlist arms ----------------------------------------------------------
for relay in "${PIN_RELAYS[@]:-}"; do
  [ -n "$relay" ] || continue
  short="${relay:0:10}"
  name="pin-cfg-$short"
  arm "$name" "\
FORWARD LEG ONLY, VIA CHANNEL ALLOWLIST. Opens exactly one outgoing channel, to
$relay, so the forward path has one candidate. The RETURN leg is untouched and
still drawn weighted-random -- which is the point: comparing this against
pin-planner isolates the return-leg striping on its own.
Needs a virgin identity, because the allowlist only constrains channels while
they are being opened. One faucet code per run."
  make_config "$OUT/$name/config.toml" 1
  cat >> "$OUT/$name/config.toml" <<EOF

[strategy]
min_open_channels    = 1
target_open_channels = 1

[strategy.channel_allowlist]
enabled = true
peers   = ["$relay"]
EOF
  touch "$OUT/$name/needs_fresh_identity"
done

# ----------------------------------------------------------------- summary --

echo
printf '%-16s %-10s %-10s %s\n' ARM HOPR.YAML FRESH-ID README
for d in "$OUT"/*/; do
  n=$(basename "$d")
  printf '%-16s %-10s %-10s %s\n' \
    "$n" \
    "$([ -f "$d/hopr.yaml" ] && echo yes || echo -)" \
    "$([ -f "$d/needs_fresh_identity" ] && echo yes || echo -)" \
    "$(head -1 "$d/README" 2>/dev/null)"
done

cat <<EOF

VALIDATE BEFORE BENCHMARKING. A manual hopr-lib config either loads or the
service refuses to start -- find that out now, not at 3am in cycle 40:

  sudo cp $OUT/pin-planner/hopr.yaml $HOPR_YAML_DEST
  sudo cp $OUT/pin-planner/config.toml /etc/gnosisvpn/config.toml
  sudo mkdir -p /etc/systemd/system/gnosisvpn.service.d
  printf '[Service]\nEnvironment=GNOSISVPN_HOPR_CONFIG_PATH=%s\n' $HOPR_YAML_DEST \\
    | sudo tee /etc/systemd/system/gnosisvpn.service.d/30-arm.conf
  sudo systemctl daemon-reload && sudo systemctl restart gnosisvpn
  sleep 5 && gnosis_vpn-ctl status
  sudo journalctl -u gnosisvpn -n 50 --no-pager | grep -i 'config\|error'

Then confirm the pin actually took, once connected:

  grep -c 'weighted candidate path' /var/log/gnosisvpn/gnosisvpn.log
  grep -o 'path=[^ ]*' /var/log/gnosisvpn/gnosisvpn.log | sort -u | head

pin-planner should show ONE distinct path per destination; auto should show many.
If both show many, the manual config did not take effect -- check the drop-in.
EOF
