#!/usr/bin/env bash
#
# 02-make-arms.sh -- render the tracked arm templates into runnable arms.
#
#   sudo ./setup/02-make-arms.sh --destination UK
#   sudo ./setup/02-make-arms.sh --destination UK --pin-relay 0xRELAY_A
#   ./setup/02-make-arms.sh --list
#
# TEMPLATES vs INSTANCES -- why this script exists at all
#
#   arms/<name>/ in the REPO is a template: prose, a hop count, a planner body,
#   optional flags. It contains no addresses, so it is safe to track, review and
#   diff. A changed planner setting shows up in a commit, which matters because a
#   silent one invalidates every comparison made after it.
#
#   $GVPN_ARMS_DIR/<name>/ in the STATE directory is an instance: the template
#   with this node's safe and module addresses substituted, and a config.toml
#   derived from the live production config. Those carry identity, so they are
#   never tracked and never inside the git worktree.
#
#   Templates are static. Instances are per-node and per-run. Conflating the two
#   is how an address ends up in a public repo.
#
# THE KEY LEVER, and it needs no recompile:
#
#   The service honours GNOSISVPN_HOPR_CONFIG_PATH. Setting it switches the
#   worker from a generated hopr-lib config to a file you supply, which exposes
#   the whole HoprLibConfig -- including protocol.path_planner:
#
#     max_cached_paths          candidates the selector may return per query
#     return_path_exploration   fraction of return draws made uniformly at random
#     return_path_weight_temper exponent flattening the return-path weights
#     min_paths_anonymity_floor candidate count below which no pruning happens
#     latency_halflife          how hard latency is weighted
#
#   max_cached_paths = 1 collapses the weighted candidate collection to a single
#   entry, so forward AND return resolve to one path, per packet, deterministically.
#   A genuine pin of both legs -- without patching hopr-lib, and without the
#   channel churn that allowlist-based pinning costs.
#
#   Two caveats this script handles:
#     * manual mode does NOT inject the safe/module addresses, so they are read
#       from the node's own gnosisvpn-hopr.safe and written into the YAML;
#     * generated mode also tightens the probe intervals to 3s for edge clients,
#       so the YAML replicates that or the node warms up far more slowly.
#
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

TEMPLATES="$GVPN_ARM_TEMPLATES"
OUT="$GVPN_ARMS_DIR"
PROD_CONFIG="${GVPN_PROD_CONFIG:-/etc/gnosisvpn/config.toml}"
SAFE_FILE="${GVPN_SAFE_FILE:-/var/lib/gnosisvpn/.config/gnosisvpn-hopr.safe}"
HOPR_YAML_DEST="${GVPN_HOPR_YAML_DEST:-/etc/gnosisvpn/hopr-arm.yaml}"
DESTINATION_ONLY="${GVPN_DESTINATION:-}"
PIN_RELAYS=()
MIN_ACK_RATE="${GVPN_MIN_ACK_RATE:-0.1}"
DO_LIST=0

usage() {
  cat <<EOF
02-make-arms.sh -- render arm templates into runnable arms

Usage: sudo $0 [--destination ID] [--pin-relay 0x...]... [--out DIR]
       $0 --list

  --destination ID      keep only this destination in the arm configs
                        (default from gvpn.conf: ${GVPN_DESTINATION:-<all>})
  --pin-relay ADDR      instantiate the _pin-cfg template against this relay.
                        Repeatable. Each needs a fresh identity, so budget one
                        faucet code per relay.
  --out DIR             where to write instances (default: $OUT)
  --templates DIR       where to read templates from (default: $TEMPLATES)
  --prod-config PATH    source config to derive from (default: $PROD_CONFIG)
  --safe-file PATH      node safe file to read addresses from
  --list                show the available templates and exit
  -h, --help

Templates live in the repo and are tracked; instances live in the state
directory ($GVPN_STATE) and are not. Run this AFTER the node has onboarded
once and reached Ready, so the safe file exists.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)          OUT="$2"; shift 2 ;;
    --templates)    TEMPLATES="$2"; shift 2 ;;
    --pin-relay)    PIN_RELAYS+=("$2"); shift 2 ;;
    --destination)  DESTINATION_ONLY="$2"; shift 2 ;;
    --prod-config)  PROD_CONFIG="$2"; shift 2 ;;
    --safe-file)    SAFE_FILE="$2"; shift 2 ;;
    --list)         DO_LIST=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$DO_LIST" = 1 ]; then
  printf '%-16s %-7s %-10s %-10s %s\n' TEMPLATE HOPS PLANNER FRESH-ID SUMMARY
  for d in "$TEMPLATES"/*/; do
    n=$(basename "$d")
    printf '%-16s %-7s %-10s %-10s %s\n' \
      "$n" "$(cat "$d/hops" 2>/dev/null || echo '?')" \
      "$([ -f "$d/planner.yaml" ] && echo yes || echo -)" \
      "$([ -f "$d/needs_fresh_identity" ] && echo yes || echo -)" \
      "$(head -1 "$d/README" 2>/dev/null)"
  done
  exit 0
fi

[ -d "$TEMPLATES" ] || { echo "no templates at $TEMPLATES" >&2; exit 1; }
[ -r "$PROD_CONFIG" ] || { echo "cannot read $PROD_CONFIG" >&2; exit 1; }

SAFE_ADDR=""; MODULE_ADDR=""
if [ -r "$SAFE_FILE" ]; then
  SAFE_ADDR=$(sed -n 's/^ *safe_address: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p'   "$SAFE_FILE" | head -1)
  MODULE_ADDR=$(sed -n 's/^ *module_address: *"\{0,1\}\([^" ]*\)"\{0,1\} *$/\1/p' "$SAFE_FILE" | head -1)
fi
if [ -z "$SAFE_ADDR" ] || [ -z "$MODULE_ADDR" ]; then
  cat >&2 <<EOF
WARNING: could not read safe/module addresses from $SAFE_FILE

The planner arms need them, because a manual hopr-lib config does not get them
injected. Onboard the node first:

    gnosis_vpn-ctl start-client 30m
    gnosis_vpn-ctl status          # wait for "Ready"

then re-run this script. The planner arms are being written with placeholders
and WILL FAIL to start until you fill them in.
EOF
  SAFE_ADDR="0xFILL_ME_IN"; MODULE_ADDR="0xFILL_ME_IN"
fi

gvpn_state_init
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

open(out, "w").write("\n".join([l.rstrip() for l in head if l.strip()] + [""] + body) + "\n")
PY
}

# Wrap a template's planner body in a complete hopr-lib config. Every field of
# HoprLibConfig has a serde default, so only deviations need stating -- but the
# struct is deny_unknown_fields, so a typo fails loudly at service start rather
# than being silently ignored. Good.
make_hopr_yaml() {  # make_hopr_yaml OUTFILE PLANNER_TEMPLATE
  local out="$1" tmpl="$2"
  {
    cat <<EOF
# Manual hopr-lib config for one benchmark arm.
# GENERATED by 02-make-arms.sh from $(basename "$(dirname "$tmpl")")/planner.yaml
# -- edit the template in the repo, not this file. Contains node addresses;
# never commit it.
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
EOF
    sed "s/@MIN_ACK_RATE@/$MIN_ACK_RATE/g; s/^/    /" "$tmpl"
  } > "$out"
}

# Render one template directory into one instance directory.
render() {  # render TEMPLATE_DIR INSTANCE_NAME [RELAY]
  local t="$1" name="$2" relay="${3:-}"
  local d="$OUT/$name" was_onboarded=0

  # PRESERVE THE ONBOARDING MARKER ACROSS A RE-RENDER.
  #
  # gvpn-bench.sh re-onboards -- which destroys the funded identity and spends a
  # faucet code -- when an arm has needs_fresh_identity and no .onboarded marker.
  # Re-rendering an arm to change a planner setting must not look like an arm
  # that has never been funded, or `make arms` silently costs you an identity and
  # a code on the next run.
  [ -f "$d/.onboarded" ] && was_onboarded=1

  rm -rf "$d"; mkdir -p "$d"
  [ "$was_onboarded" = 1 ] && touch "$d/.onboarded"

  sed "s/@RELAY@/$relay/g" "$t/README" > "$d/README"

  make_config "$d/config.toml" "$(cat "$t/hops")"
  [ -f "$t/config.append" ] && sed "s/@RELAY@/$relay/g" "$t/config.append" >> "$d/config.toml"

  if [ -f "$t/planner.yaml" ]; then
    make_hopr_yaml "$d/hopr.yaml" "$t/planner.yaml"
    printf 'GNOSISVPN_HOPR_CONFIG_PATH=%s\n' "$HOPR_YAML_DEST" > "$d/env"
  fi

  [ -f "$t/flags" ]                && cp "$t/flags" "$d/flags"
  [ -f "$t/needs_fresh_identity" ] && touch "$d/needs_fresh_identity"
  printf '%s\n' "$(basename "$t")" > "$d/.template"
  return 0
}

# -------------------------------------------------------------------- arms --

echo "templates: $TEMPLATES"
echo "instances: $OUT"
[ -n "$DESTINATION_ONLY" ] && echo "destination: $DESTINATION_ONLY (only)"
echo

for t in "$TEMPLATES"/*/; do
  name=$(basename "$t")
  case "$name" in
    _*) continue ;;   # templates instantiated per-argument, handled below
  esac
  render "$t" "$name"
  echo "  rendered $name"
done

for relay in "${PIN_RELAYS[@]:-}"; do
  [ -n "$relay" ] || continue
  name="pin-cfg-${relay:0:10}"
  render "$TEMPLATES/_pin-cfg" "$name" "$relay"
  echo "  rendered $name  (relay $relay, fresh identity required)"
done

# ----------------------------------------------------------------- summary --

echo
printf '%-20s %-10s %-10s %s\n' ARM HOPR.YAML FRESH-ID README
for d in "$OUT"/*/; do
  n=$(basename "$d")
  printf '%-20s %-10s %-10s %s\n' \
    "$n" \
    "$([ -f "$d/hopr.yaml" ] && echo yes || echo -)" \
    "$([ -f "$d/needs_fresh_identity" ] && echo yes || echo -)" \
    "$(head -1 "$d/README" 2>/dev/null)"
done

cat <<EOF

VALIDATE BEFORE BENCHMARKING. A manual hopr-lib config either loads or the
service refuses to start -- find that out now, not at 3am in cycle 40:

  sudo ./bench/use-arm.sh pin-planner --count

That installs the arm, starts the service, connects, and counts distinct routes.
pin-planner must read 1; auto must read many. If both read many the manual config
did not take effect and every later number is about nothing -- check the drop-in
at /etc/systemd/system/gnosisvpn.service.d/30-arm.conf.
EOF
