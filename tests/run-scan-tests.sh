#!/usr/bin/env bash
#
# run-scan-tests.sh -- check the secret scanner catches what it must.
#
#   ./tests/run-scan-tests.sh
#
# A scanner with a blind spot is worse than no scanner, because people stop
# reading commits carefully once they believe something else is watching. Two of
# these cases are regressions that shipped:
#
#   * `0xdeadbeef...` passed, because the benign-line list contained `0xdead`
#     and the check was applied to the whole LINE rather than to the match. Any
#     real address beginning with those four characters was exempt.
#   * only the first file in a commit was scanned, because the outer and inner
#     read loops shared stdin.
#
# It also runs under a shell with `mapfile` removed, because the hook runs on
# macOS, where bash is still 3.2.
#
set -uo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$KIT/tools/scan-secrets.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

# Remove the bash-4 builtins so a reintroduced `mapfile` fails here, not on a laptop.
cat > "$TMP/bash32" <<'EOF'
mapfile()  { echo "mapfile: command not found" >&2; return 127; }
readarray(){ echo "readarray: command not found" >&2; return 127; }
EOF

cd "$TMP"
git init -q -b main . && git config user.email t@t && git config user.name t
mkdir -p docs
echo "nothing to see" > docs/a.md
echo "nothing here either" > docs/b.md
git add -A && git commit -qm base

run() { git add -A >/dev/null 2>&1; bash -c ". '$TMP/bash32'; '$SCAN'" 2>&1; }

expect() {  # expect must_flag|must_pass NAME
  local want="$1" name="$2" out rc
  out="$(run)"; rc=$?
  if [ "$want" = must_flag ] && [ "$rc" -eq 0 ]; then
    printf '  FAIL  %s  (passed, should have been flagged)\n' "$name"; fail=1
  elif [ "$want" = must_pass ] && [ "$rc" -ne 0 ]; then
    printf '  FAIL  %s  (flagged, should have passed)\n%s\n' "$name" "$out"; fail=1
  else
    printf '  ok    %s\n' "$name"
  fi
  git reset -q >/dev/null 2>&1; git checkout -q HEAD -- . 2>/dev/null
  git clean -qfd >/dev/null 2>&1
}

echo "secret scanner"

: > docs/a.md; expect must_pass "clean tree"

echo 'safe_address: "0xabcdef0123456789abcdef0123456789abcdef01"' > docs/a.md   # scan-secrets: allow
expect must_flag "40-hex address"

# The regression: a real address whose first characters looked like a placeholder.
echo 'relay 0xdeadbeef0123456789abcdef0123456789abcdef' > docs/a.md   # scan-secrets: allow
expect must_flag "address starting 0xdead"

echo 'key 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > docs/a.md   # scan-secrets: allow
expect must_flag "64-hex private key"

echo 'peer 12D3KooWAbcdefghijklmnopqrstuvwxyz012345' > docs/a.md   # scan-secrets: allow
expect must_flag "libp2p peer id"

# The other regression: the second file must be scanned too.
echo 'harmless' > docs/a.md   # scan-secrets: allow
echo 'addr 0xabcdef0123456789abcdef0123456789abcdef01' > docs/b.md   # scan-secrets: allow
expect must_flag "leak in the SECOND file of a commit"

echo 'safe_address: "0xabcdef0123456789abcdef0123456789abcdef01"   # scan-secrets: allow' > docs/a.md
expect must_pass "allow marker exempts"

echo 'safe_address: "$SAFE_ADDR"' > docs/a.md   # scan-secrets: allow
expect must_pass "shell variable is not an address"

echo 'peers = ["@RELAY@"]' > docs/a.md   # scan-secrets: allow
expect must_pass "template placeholder"

echo 'safe_address: "0xFILL_ME_IN"' > docs/a.md   # scan-secrets: allow
expect must_pass "FILL_ME_IN placeholder"

echo
[ "$fail" = 0 ] && echo "all scanner tests passed" || echo "FAILURES above"
exit $fail
