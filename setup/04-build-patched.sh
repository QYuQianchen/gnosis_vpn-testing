#!/usr/bin/env bash
#
# 04-build-patched.sh -- build the client from source, optionally patched.
#
#   ./04-build-patched.sh --src ~/src --deps        # install toolchain + native deps
#   ./04-build-patched.sh --src ~/src               # build (unpatched first!)
#   ./04-build-patched.sh --src ~/src --install     # replace the APT binaries
#   ./04-build-patched.sh --src ~/src --restore     # put the APT binaries back
#
# PHASE 4 ONLY. Phases 0-3 need no build: the client comes from APT and the pinned
# arms are pure configuration (GNOSISVPN_HOPR_CONFIG_PATH + path_planner). Build
# only when you need to pin to a NAMED relay, which is what makes pin-busy vs
# pin-idle a controlled comparison.
#
# DO NOT BUILD ON THE VM WHILE A RUN IS IN PROGRESS. This compiles ~2000 crates
# across hoprnet and edgli: 30-90 minutes, several GB of RAM at link time, and
# 20+ GB in target/. Doing that next to a throughput measurement corrupts the
# measurement. Build before the run, or on a different machine of the same
# architecture, and copy the two binaries over.
#
# BUILD UNPATCHED FIRST. The largest risk in Phase 4 is "does this tree even build
# here", not the patch itself. Prove the toolchain on the pinned sources before
# writing a line of the patch.
#
set -euo pipefail

SRC="${GVPN_SRC_DIR:-$HOME/src}"
DO_DEPS=0
DO_INSTALL=0
DO_RESTORE=0
PROFILE="release"
JOBS="${GVPN_BUILD_JOBS:-}"

usage() {
  cat <<EOF
04-build-patched.sh -- build gnosis_vpn-client from source (Phase 4)

Usage: $0 --src DIR [--deps] [--install] [--restore]

  --src DIR    source root from 03-fetch-sources.sh (default: $SRC)
  --deps       install the Rust toolchain and native build dependencies, then exit
  --install    after building, replace /usr/bin/gnosis_vpn-{root,worker} (needs root)
  --restore    reinstall the APT binaries and exit (needs root)
  --debug      build the debug profile (faster to compile, useless for benchmarking)
  --jobs N     cargo -j N; lower it if the box OOMs at link time
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)     SRC="$2"; shift 2 ;;
    --deps)    DO_DEPS=1; shift ;;
    --install) DO_INSTALL=1; shift ;;
    --restore) DO_RESTORE=1; shift ;;
    --debug)   PROFILE="debug"; shift ;;
    --jobs)    JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
CLIENT="$SRC/gnosis_vpn-client"

# ------------------------------------------------------------------ restore --

if [ "$DO_RESTORE" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
  say "restoring the packaged binaries"
  systemctl stop gnosisvpn || true
  apt-mark unhold gnosisvpn >/dev/null 2>&1 || true
  apt-get install --reinstall -y gnosisvpn
  apt-mark hold gnosisvpn >/dev/null 2>&1 || true
  systemctl start gnosisvpn
  gnosis_vpn-ctl -V
  exit 0
fi

# --------------------------------------------------------------------- deps --

if [ "$DO_DEPS" = 1 ]; then
  # Two halves with different owners. The apt packages are system-wide and need
  # root; the Rust toolchain must belong to whoever will run the build, or it
  # lands in /root/.cargo and a non-root build cannot see it. On a box where you
  # log in as `deploy` and sudo for privileged steps, that is the difference
  # between a working toolchain and a confusing "cargo: command not found".
  BUILD_USER="${SUDO_USER:-$(id -un)}"
  BUILD_HOME=$(getent passwd "$BUILD_USER" | cut -d: -f6)
  : "${BUILD_HOME:=$HOME}"

  if [ "$(id -u)" -eq 0 ]; then
    say "native build dependencies (system-wide)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # mnl-sys / nftnl-sys need the netfilter headers and pkg-config; bindgen needs
    # clang. The rest is the usual Rust-on-Debian set.
    apt-get install -y -qq \
      build-essential pkg-config clang libclang-dev cmake \
      libmnl-dev libnftnl-dev libssl-dev \
      git curl ca-certificates protobuf-compiler >/dev/null
    echo "    installed"
  else
    say "skipping apt packages (not root)"
    echo "    run once as root:  sudo $0 --deps"
    echo "    continuing with the toolchain for $BUILD_USER"
  fi

  say "Rust toolchain for $BUILD_USER ($BUILD_HOME)"
  if [ -x "$BUILD_HOME/.cargo/bin/rustup" ]; then
    echo "    already present: $("$BUILD_HOME/.cargo/bin/rustup" --version 2>&1 | head -1)"
  else
    # rust-toolchain.toml pins the channel (1.98 at the time of writing), so rustup
    # selects the right one automatically on first cargo invocation in the repo.
    INSTALL='curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path'
    if [ "$(id -u)" -eq 0 ] && [ "$BUILD_USER" != "root" ]; then
      # Drop back to the invoking user so ~/.cargo is theirs, not root's.
      su - "$BUILD_USER" -c "$INSTALL"
    else
      eval "$INSTALL"
    fi
    echo "    installed to $BUILD_HOME/.cargo"
  fi
  echo
  echo "    Put it on PATH in the shell you will BUILD from (not under sudo):"
  echo "      . $BUILD_HOME/.cargo/env"

  cat <<'EOF'

Resource check before you start a build:
  free -g        link time wants several GB; 4 GB total is tight, 8 GB is comfortable
  df -h /        target/ across hoprnet + edgli runs to 20 GB+
  nproc          expect 30-90 minutes

If the box OOMs while linking, re-run the build with --jobs 2.

Alternative: the repo's supported build path is Nix, which produces the same
static binaries the .deb ships:
  sh <(curl -L https://nixos.org/nix/install) --daemon
  cd gnosis_vpn-client && nix build -L .#binary-gnosis_vpn-x86_64-linux
  # result/bin/gnosis_vpn-{root,worker,ctl}
Nix is slower to set up and much harder to get wrong. Prefer it if cargo fights you.
EOF
  exit 0
fi

# -------------------------------------------------------------------- build --

[ -d "$CLIENT" ] || { echo "no client sources at $CLIENT -- run 03-fetch-sources.sh first" >&2; exit 1; }
command -v cargo >/dev/null 2>&1 || { echo "cargo not found. Run: sudo $0 --deps ; then . \$HOME/.cargo/env" >&2; exit 1; }

say "build environment"
echo "    $(rustc --version 2>&1)"
echo "    toolchain pin: $(grep -m1 channel "$CLIENT/rust-toolchain.toml" 2>/dev/null || echo '?')"
# .cargo/config.toml already sets --cfg tokio_unstable for [build]; the flake sets
# CARGO_BUILD_RUSTFLAGS instead, and that REPLACES [build] rather than merging.
# So if anything in the environment has set it, the tokio flags must be re-added.
if [ -n "${CARGO_BUILD_RUSTFLAGS:-}" ]; then
  case "$CARGO_BUILD_RUSTFLAGS" in
    *tokio_unstable*) : ;;
    *) export CARGO_BUILD_RUSTFLAGS="$CARGO_BUILD_RUSTFLAGS --cfg tokio_unstable --check-cfg cfg(tokio_unstable)"
       echo "    re-added tokio_unstable to CARGO_BUILD_RUSTFLAGS" ;;
  esac
fi

# Patched hoprnet/edgli go in via [patch], never by editing Cargo.toml's rev.
if [ -f "$CLIENT/.cargo/config.local.toml" ] || grep -q '^\[patch' "$CLIENT/Cargo.toml" 2>/dev/null; then
  say "patch overrides detected in the manifest"
  grep -A 6 '^\[patch' "$CLIENT/Cargo.toml" || true
  cat <<'EOF'

    Reminder: both `edgli` and `hopr-utils-session` must resolve to the SAME
    hoprnet source, in the SAME form. `?branch=X#sha` and `?rev=sha` are distinct
    sources to Cargo even for identical commits -- mixing them builds hoprnet
    twice and fails with `expected hopr_lib::HoprSessionClientConfig, found
    HoprSessionClientConfig`. The comment in the client's Cargo.toml says the
    same thing; it is there because someone already lost a day to it.
EOF
fi

say "building ($PROFILE)"
cd "$CLIENT"
BUILD_ARGS=(--workspace)
[ "$PROFILE" = "release" ] && BUILD_ARGS+=(--release)
[ -n "$JOBS" ] && BUILD_ARGS+=(-j "$JOBS")

START=$(date +%s)
cargo build "${BUILD_ARGS[@]}"
echo "    built in $(( ($(date +%s) - START) / 60 )) min"

TARGET="$CLIENT/target/$PROFILE"
ls -l "$TARGET"/gnosis_vpn-root "$TARGET"/gnosis_vpn-worker "$TARGET"/gnosis_vpn-ctl 2>/dev/null || true

# ------------------------------------------------------------------ install --

if [ "$DO_INSTALL" = 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo "--install needs root" >&2; exit 1; }
  say "installing over the packaged binaries"

  # apt is already held by 00-vm-setup.sh; keep it that way so an upgrade cannot
  # silently replace a patched binary in the middle of a run.
  apt-mark hold gnosisvpn >/dev/null 2>&1 || true

  systemctl stop gnosisvpn
  for b in gnosis_vpn-root gnosis_vpn-worker gnosis_vpn-ctl; do
    [ -f "/usr/bin/$b" ] && [ ! -f "/usr/bin/$b.apt" ] && cp -a "/usr/bin/$b" "/usr/bin/$b.apt"
    install -m 0755 "$TARGET/$b" "/usr/bin/$b"
  done
  # The worker runs as the unprivileged gnosisvpn user and must be able to exec it.
  chmod 0755 /usr/bin/gnosis_vpn-worker
  systemctl start gnosisvpn
  sleep 3
  gnosis_vpn-ctl -V
  systemctl is-active gnosisvpn

  cat <<EOF

    Packaged binaries saved as /usr/bin/<name>.apt
    Undo with: sudo $0 --restore

    RECORD THE BUILD IDENTITY IN THE RUN. A patched binary that is not written
    down is a result nobody can reproduce:
      gnosis_vpn-ctl -V
      git -C $CLIENT log -1 --format='%H %s'
      git -C $CLIENT status --porcelain
EOF
fi

cat <<EOF

Sanity checks before benchmarking a patched build:
  gnosis_vpn-ctl -V
  sudo systemctl status gnosisvpn --no-pager
  sudo journalctl -u gnosisvpn -n 50 --no-pager | grep -iE 'error|panic|config'

Then re-run the smoke profile and confirm the pin still reports one path:
  sudo ./bench/gvpn-bench.sh -s <IPERF_HOST> --profile smoke --arms-dir ./arms
  grep -o 'path=[^ ]*' /var/log/gnosisvpn/gnosisvpn.log | sort -u | head
EOF
