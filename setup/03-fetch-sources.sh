#!/usr/bin/env bash
#
# 03-fetch-sources.sh -- clone the exact source revisions this build is made of.
#
#   ./03-fetch-sources.sh --out ~/src
#
# YOU DO NOT NEED THIS TO RUN THE BENCHMARK. The client is installed from APT and
# the pinned arms are pure configuration. Fetch sources when you want to
#   * read the code while interpreting results (which log line means what),
#   * confirm a config key exists in the version you are actually running,
#   * prepare the optional Phase 4 patch.
#
# WHY THE REVISIONS MATTER. gnosis_vpn-client pins edgli and hopr-utils-session by
# git revision, and edgli in turn pins hopr-lib by revision. Cargo treats
# `?branch=X#sha` and `?rev=sha` as DIFFERENT sources even for byte-identical
# commits -- mix the two forms and the workspace builds hoprnet twice, then fails
# with a type mismatch between two copies of the same struct. This script reads the
# revisions out of the client's own Cargo.toml rather than hardcoding them, so the
# checkouts always agree with the manifest.
#
set -euo pipefail

OUT="${GVPN_SRC_DIR:-$HOME/src}"
CLIENT_REF="${GVPN_CLIENT_REF:-main}"
SHALLOW=1

usage() {
  cat <<EOF
03-fetch-sources.sh -- clone the pinned sources for the #8408 work

Usage: $0 [--out DIR] [--client-ref REF] [--full]

  --out DIR         where to clone (default: $OUT)
  --client-ref REF  branch/tag/sha of gnosis_vpn-client (default: $CLIENT_REF)
                    use the tag matching your installed version for an exact match:
                      gnosis_vpn-ctl -V
  --full            full clones instead of shallow (needed to build: the client
                    embeds its git sha via vergen, and to check out arbitrary revs)
  -h, --help

Repositories fetched:
  gnosis/gnosis_vpn-client   the client itself
  gnosis/gnosis_vpn          packaging: installer, systemd unit, network configs
  hoprnet/edge-client        edgli, at the revision the client pins
  hoprnet/hoprnet            hopr-lib and the transport, at the revision edgli pins
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --out)        OUT="$2"; shift 2 ;;
    --client-ref) CLIENT_REF="$2"; shift 2 ;;
    --full)       SHALLOW=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "git not found; apt-get install -y git" >&2; exit 1; }
mkdir -p "$OUT"
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Clone and check out a revision.
#
# The pinned revisions are frequently NOT on any branch -- the client currently
# pins edgli at a merge commit whose branch has since moved on. `git clone`
# followed by `git checkout <sha>` then fails with "reference is not a tree",
# even from a full clone, because the commit is unreachable from any ref.
# GitHub does allow fetching such a commit by SHA directly, so that is the
# fallback: `git fetch origin <sha>` then check out FETCH_HEAD.
clone() {  # clone URL DIR [REF]
  local url="$1" dir="$2" ref="${3:-}"

  if [ -d "$dir/.git" ]; then
    echo "    $dir already present; fetching"
    git -C "$dir" fetch --all --tags --quiet || true
  elif [ "$SHALLOW" = 1 ] && [ -z "$ref" ]; then
    git clone --depth 1 --quiet "$url" "$dir"
  else
    # blob:none keeps the clone quick without losing history, which matters for
    # hoprnet (large) and for resolving refs that are not the tip.
    git clone --filter=blob:none --quiet "$url" "$dir"
  fi

  if [ -n "$ref" ]; then
    if ! git -C "$dir" checkout --quiet "$ref" 2>/dev/null; then
      echo "    $ref is not on a branch here; fetching it by SHA"
      if git -C "$dir" fetch --quiet origin "$ref" 2>/dev/null; then
        git -C "$dir" checkout --quiet FETCH_HEAD || {
          echo "    could not check out $ref in $dir" >&2; return 1; }
      else
        echo "    could not fetch $ref from $url" >&2
        echo "    (the commit may have been garbage-collected; check the manifest)" >&2
        return 1
      fi
    fi
  fi

  printf '    %-28s %s\n' "$(basename "$dir")" \
    "$(git -C "$dir" log -1 --format='%h %ad %s' --date=short)"
}

# --------------------------------------------------------------- the client --

say "gnosis_vpn-client ($CLIENT_REF)"
[ "$CLIENT_REF" = "main" ] || SHALLOW=0
clone https://github.com/gnosis/gnosis_vpn-client.git "$OUT/gnosis_vpn-client" \
      "$([ "$CLIENT_REF" = main ] && echo "" || echo "$CLIENT_REF")"

say "gnosis_vpn (packaging: installer, systemd unit, network configs)"
clone https://github.com/gnosis/gnosis_vpn.git "$OUT/gnosis_vpn"

# --------------------------------------------- revisions, read from the manifest --

MANIFEST="$OUT/gnosis_vpn-client/Cargo.toml"
EDGLI_REV=$(sed -n '/^edgli *=/,/}/p' "$MANIFEST" \
            | grep -o 'rev *= *"[0-9a-f]\{7,40\}"' | head -1 | grep -o '[0-9a-f]\{7,40\}' || true)
HOPRNET_REV=$(sed -n '/^hopr-utils-session *=/,/}/p' "$MANIFEST" \
            | grep -o 'rev *= *"[0-9a-f]\{7,40\}"' | head -1 | grep -o '[0-9a-f]\{7,40\}' || true)

echo
echo "revisions pinned by $MANIFEST:"
echo "  edgli   (hoprnet/edge-client): ${EDGLI_REV:-<not found>}"
echo "  hoprnet (hopr-utils-session):  ${HOPRNET_REV:-<not found>}"

if [ -z "$EDGLI_REV" ] || [ -z "$HOPRNET_REV" ]; then
  cat >&2 <<'EOF'

WARNING: could not parse one or both revisions out of Cargo.toml. Either the
manifest now pins by branch rather than rev, or the formatting changed. Check by
hand and clone those revisions explicitly -- getting this wrong is how you end up
analysing a different version of the code than you are running.
EOF
fi

say "hoprnet/edge-client${EDGLI_REV:+ @ $EDGLI_REV}"
SHALLOW=0 clone https://github.com/hoprnet/edge-client.git "$OUT/edge-client" "${EDGLI_REV:-}"

say "hoprnet/hoprnet${HOPRNET_REV:+ @ $HOPRNET_REV}"
SHALLOW=0 clone https://github.com/hoprnet/hoprnet.git "$OUT/hoprnet" "${HOPRNET_REV:-}"

# Cross-check: edgli pins hopr-lib itself, and it must match what the client pins.
EDGLI_HOPR_REV=$(sed -n '/hopr-lib *=/,/}/p' "$OUT/edge-client/Cargo.toml" 2>/dev/null \
                 | grep -o 'rev *= *"[0-9a-f]\{7,40\}"' | head -1 | grep -o '[0-9a-f]\{7,40\}' || true)
if [ -n "$EDGLI_HOPR_REV" ] && [ -n "$HOPRNET_REV" ] && [ "$EDGLI_HOPR_REV" != "$HOPRNET_REV" ]; then
  cat >&2 <<EOF

NOTE: edgli pins hopr-lib at $EDGLI_HOPR_REV while the client pins
      hopr-utils-session at $HOPRNET_REV. If you patch hoprnet, both consumers
      must end up on the SAME revision and the SAME source form, or the build
      produces two copies of hoprnet and fails with a confusing type mismatch.
EOF
fi

# ---------------------------------------------------------------- summary --

cat <<EOF

Sources in $OUT:
  gnosis_vpn-client/   client, worker, ctl, shared library
  gnosis_vpn/          installer + linux/resources/{config-jura-prod.toml,gnosisvpn.service}
  edge-client/         edgli; src/lib.rs:59 is latency_path_planner_config()
  hoprnet/             transport/hopr/src/path/{planner.rs,selector.rs} -- the path draw
                       transport/hopr/src/config.rs  -- PathPlannerConfig fields
                       hopr/hopr-lib/src/config.rs   -- HoprLibConfig (the manual YAML schema)

Useful while interpreting results:
  # every field the manual hopr.yaml may contain, with defaults and doc comments
  less $OUT/hoprnet/transport/hopr/src/path/planner.rs      # PathPlannerConfig
  less $OUT/hoprnet/hopr/hopr-lib/src/config.rs             # HoprLibConfig

  # what the DEBUG lines the analyser parses actually mean
  grep -n 'weighted candidate path' -B 20 $OUT/hoprnet/transport/hopr/src/path/planner.rs

Next (optional, Phase 4 only): ./04-build-patched.sh --src $OUT
EOF
