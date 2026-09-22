#!/usr/bin/env bash
#
# backup-identity.sh -- encrypted backup and restore of the node identity.
#
#   sudo ./tools/backup-identity.sh                    back up, then verify
#   sudo ./tools/backup-identity.sh --restore FILE     restore from a backup
#   ./tools/backup-identity.sh --list                  what backups exist
#
# WHY THIS IS A SCRIPT AND NOT A LINE IN A RUNBOOK
#
#   Onboarding is the only step in this kit that costs real money and real time to
#   redo: a faucet code, channel funding, and an hour of waiting for Ready. The
#   backup has to be right on the first attempt, at the moment someone is already
#   in a hurry, and three details are easy to get wrong by hand:
#
#     * the service must be stopped, or tar can catch a half-written identity --
#       a backup that restores to a corrupt identity is worse than no backup,
#       because you do not find out until the day you need it;
#     * `gpg -c` cannot prompt for a passphrase when tar is occupying stdin on a
#       headless box -- it dies with "problem with the agent: Inappropriate ioctl
#       for device". openssl takes the passphrase on a file descriptor and needs
#       no agent or keyring at all;
#     * an unverified backup is a hope. This one decrypts and lists what it just
#       wrote before it reports success.
#
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

IDENTITY_DIR="${GVPN_IDENTITY_DIR:-/var/lib/gnosisvpn/.config}"
DEST="$GVPN_BACKUP_DIR"
SERVICE="${GVPN_SERVICE:-gnosisvpn}"
MODE=backup
RESTORE_FROM=""

# 600k PBKDF2 iterations: this protects an offline file, so the cost of a guess
# is the only defence. It adds well under a second to a backup that happens once.
ENC=(-aes-256-cbc -pbkdf2 -iter 600000)

usage() { sed -n '2,28p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --restore) MODE=restore; RESTORE_FROM="$2"; shift 2 ;;
    --list)    MODE=list; shift ;;
    --dest)    DEST="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

if [ "$MODE" = list ]; then
  say "backups in $DEST"
  ls -lh "$DEST"/*.enc 2>/dev/null || echo "  (none)"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo (the identity is root-owned)" >&2; exit 1; }

ask_passphrase() {  # ask_passphrase CONFIRM(0|1)
  # Read from the controlling terminal explicitly: stdin may be a pipe, and this
  # script is often run from one.
  exec 4</dev/tty || { echo "no terminal to ask for a passphrase" >&2; exit 1; }
  printf 'Backup passphrase: ' >&2; IFS= read -rs BK <&4; printf '\n' >&2
  if [ "$1" = 1 ]; then
    printf 'Again:             ' >&2; IFS= read -rs BK2 <&4; printf '\n' >&2
    [ "$BK" = "$BK2" ] || { echo "passphrases do not match" >&2; exit 1; }
    unset BK2
  fi
  [ -n "$BK" ] || { echo "empty passphrase" >&2; exit 1; }
  exec 4<&-
}

svc() { systemctl "$1" "$SERVICE" 2>/dev/null || true; }

# ------------------------------------------------------------------ restore --

if [ "$MODE" = restore ]; then
  [ -r "$RESTORE_FROM" ] || { echo "cannot read $RESTORE_FROM" >&2; exit 1; }
  ask_passphrase 0

  say "checking the archive before touching anything"
  openssl enc -d "${ENC[@]}" -pass fd:3 -in "$RESTORE_FROM" 3< <(printf %s "$BK") \
    | tar tzf - || { echo "archive did not decrypt -- nothing was changed" >&2; exit 1; }

  say "restoring into $IDENTITY_DIR"
  svc stop; sleep 2
  # Keep whatever is there now. If this restore is the wrong archive, the thing
  # it overwrote is the only copy of the current identity.
  if [ -d "$IDENTITY_DIR" ]; then
    mv "$IDENTITY_DIR" "$IDENTITY_DIR.before-restore-$(date -u +%Y%m%d%H%M%S)"
    echo "    previous identity kept alongside as .before-restore-*"
  fi
  mkdir -p "$(dirname "$IDENTITY_DIR")"
  openssl enc -d "${ENC[@]}" -pass fd:3 -in "$RESTORE_FROM" 3< <(printf %s "$BK") \
    | tar xzf - -C "$(dirname "$IDENTITY_DIR")"
  chown -R "$(stat -c '%U:%G' "$(dirname "$IDENTITY_DIR")")" "$IDENTITY_DIR" 2>/dev/null || true
  svc start
  unset BK
  say "restored. Wait for Ready, then confirm the safe address is the funded one:"
  echo "  gnosis_vpn-ctl start-client 30m && gnosis_vpn-ctl status"
  exit 0
fi

# ------------------------------------------------------------------- backup --

[ -d "$IDENTITY_DIR" ] || { echo "no identity at $IDENTITY_DIR" >&2; exit 1; }
gvpn_state_init
umask 077
mkdir -p "$DEST"

OUT="$DEST/identity-$(date -u +%Y%m%d-%H%M%S).tar.gz.enc"
ask_passphrase 1

say "stopping $SERVICE so the identity is not written while it is read"
svc stop; sleep 2

tar czf - -C "$(dirname "$IDENTITY_DIR")" "$(basename "$IDENTITY_DIR")" \
  | openssl enc "${ENC[@]}" -salt -pass fd:3 -out "$OUT" 3< <(printf %s "$BK")

svc start

say "verifying -- decrypting what was just written"
if ! openssl enc -d "${ENC[@]}" -pass fd:3 -in "$OUT" 3< <(printf %s "$BK") | tar tzf -; then
  echo "VERIFY FAILED -- do not rely on $OUT" >&2
  unset BK; exit 1
fi
unset BK

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  chown "$SUDO_USER" "$OUT" 2>/dev/null || true
fi
chmod 600 "$OUT"

say "backup verified: $OUT  ($(du -h "$OUT" | cut -f1))"
cat <<EOF

NOW COPY IT OFF THIS MACHINE. An encrypted backup that exists only on the box it
protects is not a backup -- it shares the disk failure it is supposed to survive.

  scp gvpn-vm:${OUT/#$HOME/\~} .

Restore with:  sudo ./tools/backup-identity.sh --restore <file>
EOF
