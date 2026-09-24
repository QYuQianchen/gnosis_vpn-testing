#!/usr/bin/env bash
# Arm config rendering, against a base shaped like the packaged network configs.
#
# The regression this pins: the packaged configs already contain
# [connection.path_planner], and arms used to APPEND a second one. TOML rejects a
# table declared twice, gnosis_vpn-root maps that to exit 66, and the service
# will not start. Every arm template is rendered here and must parse.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
M="$KIT/lib/tomlmerge.py"
BASE="$KIT/tests/fixtures/config-network.toml"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RELAY="0x$(printf '0%.0s' $(seq 38))cc"      # a dummy relay, built so no address literal is committed
fail=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }

val() {  # val FILE dotted.key  -> the parsed value, or <missing>
  python3 - "$1" "$2" <<'PY'
import sys, tomllib
t = tomllib.load(open(sys.argv[1], "rb"))
for p in sys.argv[2].split("."):
    if not isinstance(t, dict) or p not in t:
        print("<missing>"); sys.exit()
    t = t[p]
print(t)
PY
}

echo "config rendering"

# 1. the old behaviour really is broken -- keep the evidence in the suite
cat "$BASE" "$KIT/arms/pin-planner/config.append" > "$TMP/appended.toml"
if python3 "$M" check "$TMP/appended.toml" >/dev/null 2>&1; then
  bad "appending the arm to the base should fail (duplicate table)"
else
  ok "appending [connection.path_planner] to the base is rejected, as the client does"
fi

# 2. every template renders, parses, and keeps one copy of each table
for t in "$KIT"/arms/*/; do
  name=$(basename "$t"); hops=$(cat "$t/hops")
  over="-"; [ -f "$t/config.append" ] && { sed "s/@RELAY@/$RELAY/g" \
      "$t/config.append" > "$TMP/$name.over"; over="$TMP/$name.over"; }
  if python3 "$M" render "$BASE" "$over" "$TMP/$name.toml" --hops "$hops" \
       --destination UK --label "$name" 2>"$TMP/$name.err"; then
    python3 "$M" check "$TMP/$name.toml" >/dev/null && ok "$name renders and parses" \
      || bad "$name rendered but does not parse"
  else
    bad "$name failed to render: $(cat "$TMP/$name.err")"
  fi
done

# 3. the merged values are the arm's, and the base's other keys survive
f="$TMP/pin-planner.toml"
[ "$(val "$f" connection.path_planner.max_cached_paths)" = 1 ]          && ok "pin-planner: max_cached_paths = 1" || bad "pin-planner: max_cached_paths"
[ "$(val "$f" connection.path_planner.return_path_exploration)" = 0.0 ] && ok "pin-planner: return_path_exploration = 0.0" || bad "pin-planner: exploration"
[ "$(val "$f" connection.path_planner.min_paths_anonymity_floor)" = 3 ] && ok "pin-planner: base's anonymity floor kept" || bad "pin-planner: base key lost"
[ "$(grep -c '^\[connection.path_planner\]' "$f")" = 1 ]                && ok "pin-planner: exactly one [connection.path_planner]" || bad "pin-planner: duplicate table"

f="$TMP/auto.toml"
[ "$(val "$f" connection.path_planner.min_paths_anonymity_floor)" = 3 ] && ok "auto: base planner untouched" || bad "auto: base planner changed"
[ "$(val "$f" connection.path_planner.max_cached_paths)" = "<missing>" ] && ok "auto: no planner override" || bad "auto: unexpected override"

f="$TMP/_pin-cfg.toml"
[ "$(val "$f" strategy.min_open_channels)" = 1 ]                  && ok "pin-cfg: strategy merged into the existing table" || bad "pin-cfg: strategy merge"
[ "$(val "$f" strategy.channel_allowlist.enabled)" = True ]       && ok "pin-cfg: allowlist enabled" || bad "pin-cfg: allowlist"
python3 -c "import tomllib,sys; p=tomllib.load(open('$f','rb'))['strategy']['channel_allowlist']['peers']; sys.exit(p!=['$RELAY'])" \
  && ok "pin-cfg: multi-line peers array replaced, not appended to" || bad "pin-cfg: peers"

# 4. destinations: only the chosen one, with the forced hop count
f="$TMP/zero-hop.toml"
[ "$(val "$f" destinations.UK.path.hops)" = 0 ]    && ok "zero-hop: path = { hops = 0 }" || bad "zero-hop: hops"
[ "$(val "$f" destinations.USA)" = "<missing>" ]   && ok "other destinations dropped" || bad "other destinations kept"
python3 "$M" render "$BASE" - "$TMP/x.toml" --hops 1 --destination Mars 2>/dev/null \
  && bad "an unknown destination should be refused" || ok "an unknown destination is refused"

echo
[ "$fail" = 0 ] && echo "all config tests passed" || echo "FAILURES above"
exit $fail
