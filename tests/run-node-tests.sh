#!/usr/bin/env bash
# The node's config lifecycle, in a sandbox with systemctl/dpkg/apt-get stubbed:
# damage -> repair -> render arms -> install an arm -> re-render -> roll back.
#
# This is the path that broke a real node: arms written THROUGH the config.toml
# symlink into the packaged config, a duplicate [connection.path_planner], exit
# 66, and "backups" that were symlinks to the damaged file.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/etc" "$SB/bin" "$SB/log"
fail=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }
check() { python3 "$KIT/lib/tomlmerge.py" check "$1" >/dev/null 2>&1; }

PRISTINE="$SB/pristine.toml"; NET="$SB/etc/config-jura-prod.toml"
cp "$KIT/tests/fixtures/config-network.toml" "$PRISTINE"
cat "$PRISTINE" "$KIT/arms/pin-planner/config.append" > "$NET"     # the old damage
ln -s "$NET" "$SB/etc/config.toml"
ln -s "$NET" "$SB/etc/config.toml.use-arm-backup"

# systemctl: "active" iff the linked config parses. dpkg: verify by content.
# apt-get: --force-confmiss semantics -- restores the file only if MISSING.
cat > "$SB/bin/systemctl" <<EOF
#!/bin/sh
c() { python3 "$KIT/lib/tomlmerge.py" check "\$(readlink -f "$SB/etc/config.toml")" >/dev/null 2>&1; }
case "\$*" in
  *is-active*)      c ;;
  *ExecMainStatus*) c && echo 0 || echo 66 ;;
  *NRestarts*)      echo 0 ;;
esac
exit 0
EOF
cat > "$SB/bin/dpkg" <<EOF
#!/bin/sh
case "\$1" in
  -S)       echo "gnosisvpn: \$2" ;;
  --verify) cmp -s "$PRISTINE" "$NET" || echo "??5??????  c $NET" ;;
esac
EOF
cat > "$SB/bin/apt-get" <<EOF
#!/bin/sh
[ -e "$NET" ] || cp "$PRISTINE" "$NET"
EOF
# The scripts refuse to run without root; everything they touch here is in the
# sandbox, so let them through without sudo (this suite used to pass only as root).
REAL_ID="$(command -v id)"
cat > "$SB/bin/id" <<EOF
#!/bin/sh
[ "\$1" = -u ] && { echo 0; exit 0; }
exec "$REAL_ID" "\$@"
EOF
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH" GVPN_CONFIG_DIR="$SB/etc" GNOSISVPN_CONFIG_PATH="$SB/etc/config.toml" \
       GVPN_SERVICE_LOG="$SB/log/g.log" GVPN_STATE="$SB/state" GVPN_DESTINATION=UK

echo "node config lifecycle"

check "$NET" && bad "the damaged config should not parse" \
             || ok "damaged config is rejected (duplicate table), as the client does"
bash "$KIT/setup/02-make-arms.sh" >/dev/null 2>&1 \
  && bad "arms must not render from a broken network config" \
  || ok "02-make-arms refuses to derive from the broken config"

bash "$KIT/tools/restore-config.sh" --apply >/dev/null 2>&1 \
  && ok "restore-config --apply succeeds" || bad "restore-config --apply failed"
cmp -s "$PRISTINE" "$NET" && ok "network config is byte-identical to the packaged one" \
                          || bad "network config not restored"
[ -L "$SB/etc/config.toml.use-arm-backup" ] && bad "symlink backup left behind" \
                                            || ok "symlink 'backups' removed"
ls "$SB/etc/"*.damaged-* >/dev/null 2>&1 && ok "damaged copy kept as evidence" \
                                         || bad "damaged copy not kept"

bash "$KIT/setup/02-make-arms.sh" >/dev/null 2>&1 && ok "arms render from the repaired config" \
                                                 || bad "arms failed to render"
A="$SB/state/arms"
(. "$KIT/lib/common.sh"; gvpn_install_arm "$A/pin-planner/config.toml") \
  && ok "pin-planner installs" || bad "pin-planner install failed"
[ "$(readlink "$SB/etc/config.toml")" = "$SB/etc/config-gvpn-arm.toml" ] \
  && ok "config.toml re-pointed at the arm's own file" || bad "symlink not re-pointed"
cmp -s "$PRISTINE" "$NET" && ok "installing an arm leaves the packaged config untouched" \
                          || bad "installing an arm modified the packaged config"
check "$SB/etc/config-gvpn-arm.toml" && ok "installed arm config parses" \
                                     || bad "installed arm config does not parse"

# Capture, then match: `cmd | grep -q` under pipefail fails on the SIGPIPE the
# writer gets when grep exits early, even though the match succeeded.
out="$(bash "$KIT/setup/02-make-arms.sh" 2>/dev/null)"
grep -q "^base: *$NET\$" <<<"$out" \
  && ok "re-render with an arm active still derives from the network config" \
  || bad "re-render derived from the active arm"
[ "$(grep -c '^\[connection.path_planner\]' "$A/pin-planner/config.toml")" = 1 ] \
  && ok "no compounding: one [connection.path_planner] after re-render" || bad "tables compounded"

(. "$KIT/lib/common.sh"; gvpn_restore_original) && [ "$(readlink "$SB/etc/config.toml")" = "$NET" ] \
  && ok "rollback re-points config.toml at the network config" || bad "rollback failed"
bash "$KIT/setup/02-make-arms.sh" --base "$SB/etc/config-gvpn-arm.toml" >/dev/null 2>&1 \
  && bad "a rendered arm must be refused as a base" || ok "a rendered arm is refused as a base"

echo
[ "$fail" = 0 ] && echo "all node tests passed" || echo "FAILURES above"
exit $fail
