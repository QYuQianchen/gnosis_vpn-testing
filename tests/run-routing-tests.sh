#!/usr/bin/env bash
# The kernel behaviour the SSH bypass's gateway link route exists for.
# Needs an unprivileged network namespace; skips (passes) where there is none.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "routing (kernel nexthop check)"
if ! unshare -n true 2>/dev/null; then
  echo "  skip  no network namespace available here (e.g. macOS) -- run on Linux"
  echo; echo "all routing tests passed (skipped)"; exit 0
fi
if unshare -n python3 "$KIT/tests/netlink_onlink.py"; then
  echo; echo "all routing tests passed"
else
  echo; echo "FAILURES above"; exit 1
fi
