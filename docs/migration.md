# Migrating the VM to the state-directory layout

One-time, ~5 minutes. Do it **between runs** — the deploy hook now refuses a push
while `run.lock` exists, and you do not want to find that out mid-soak.

What changes: raw runs, rendered arms and faucet codes move out of `~/gvpn-8408`
into `~/gvpn-state`. Nothing is deleted by this procedure; the old directories are
moved, not removed, so a mistake is recoverable by moving them back.

## Your funded identity is not affected

The node identity and its funded safe live in `/var/lib/gnosisvpn/.config/`, a
system path owned by the service. It has never been inside `~/gvpn-8408` and it
does not move into `~/gvpn-state`. Nothing in this procedure reads it except the
backup below, and nothing in the kit purges the package.

The only thing that ever replaces a funded identity is an arm marked
`needs_fresh_identity` — that is `pin-cfg-*` and nothing else. The default study
(`auto`, `pin-planner`, `no-explore`) never triggers it. Take the backup anyway:
it costs a minute, and re-onboarding costs a faucet code and an hour of waiting.

## Before you push anything

Confirm nothing is running, and take the backup first. Onboarding is the one step
in this whole kit that costs real money and real time to redo.

```sh
ssh gvpn-vm
cd ~/gvpn-8408
pgrep -af gvpn-bench.sh          # must print nothing
ls bench-runs/*/deadline 2>/dev/null   # must print nothing
```

The kit now has a script for this — `make backup` — which stops the service,
encrypts, restarts, then decrypts what it wrote to prove it is readable. The
commands below are what it runs, for when you want to do it by hand.

`openssl` rather than `gpg` on purpose. `gpg -c` asks its agent to prompt for a
passphrase, and on a headless server with `tar` already occupying stdin the agent
has no terminal to prompt on — it fails with `problem with the agent:
Inappropriate ioctl for device`. `openssl enc` takes the passphrase on a file
descriptor, needs no agent and no keyring, and is installed everywhere.

```sh
umask 077
mkdir -p ~/gvpn-state/identity-backup

read -rsp 'Backup passphrase: ' BK; echo
read -rsp 'Again: '            BK2; echo
[ "$BK" = "$BK2" ] || { echo "MISMATCH - start over"; unset BK BK2; }

OUT=~/gvpn-state/identity-backup/identity-$(date -u +%Y%m%d).tar.gz.enc

# Stop the service first: copying the identity while it is running can catch a
# half-written file, and a backup that restores to a corrupt identity is worse
# than none, because you will not find out until you need it.
sudo systemctl stop gnosisvpn
sudo tar czf - -C /var/lib/gnosisvpn .config \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -pass fd:3 -out "$OUT" 3< <(printf %s "$BK")
sudo systemctl start gnosisvpn

# VERIFY IT. A backup you have never restored is not a backup, it is a hope.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
      -pass fd:3 -in "$OUT" 3< <(printf %s "$BK") | tar tzf -

unset BK BK2
ls -l "$OUT"
```

The listing must show `.config/gnosisvpn-hopr.id` — that is the file that is the
identity. `3< <(printf %s "$BK")` passes the passphrase through a pipe rather
than a here-string, so it never touches a temp file, and it survives a passphrase
containing quotes or `$`.

Copy that file off the VM. An encrypted backup that only exists on the machine it
protects is not a backup.

To restore, later:

```sh
sudo systemctl stop gnosisvpn
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass fd:3 \
      -in identity-YYYYMMDD.tar.gz.enc 3< <(printf %s "$BK") \
  | sudo tar xzf - -C /var/lib/gnosisvpn
sudo chown -R gnosisvpn: /var/lib/gnosisvpn/.config 2>/dev/null
sudo systemctl start gnosisvpn
```

## Move the state

**These need `sudo`.** `arms/` and `bench-runs/` were written by scripts run
under `sudo`, so they are owned by root even though they sit in your home
directory. That is also why this step cannot be skipped: the deploy runs as you,
and `git read-tree` cannot create `arms/_pin-cfg/` inside a root-owned `arms/`.
Skipping it produces exactly this, which names the symptom and not the cause:

```
fatal: cannot create directory at 'arms/_pin-cfg': Permission denied
 ! [remote rejected] main -> main (push-to-checkout hook declined)
```

```sh
cd ~/gvpn-8408
mkdir -p ~/gvpn-state/{runs,arms,secrets}
chmod 700 ~/gvpn-state/secrets

[ -d bench-runs ] && sudo mv bench-runs/* ~/gvpn-state/runs/ 2>/dev/null
sudo rmdir bench-runs 2>/dev/null
[ -d arms ]       && sudo mv arms    ~/gvpn-state/arms-old
# The bench now looks for codes here by default; leaving them in the repo means
# the next pin-cfg arm finds none and the run aborts at that arm.
[ -f faucet-codes ]      && mv faucet-codes      ~/gvpn-state/secrets/
[ -f faucet-codes.used ] && mv faucet-codes.used ~/gvpn-state/secrets/
chmod 600 ~/gvpn-state/secrets/faucet-codes* 2>/dev/null

sudo chown -R "$(id -un)": ~/gvpn-state

ls ~/gvpn-state/runs | head        # your old runs, still there

# nothing left in the worktree that the deploy user cannot write
find . -path ./.git -prune -o ! -user "$(id -un)" -print 2>/dev/null | head
```

The last command must print nothing. From this version on the deploy hook runs
that check itself and refuses the push with the real explanation rather than
letting `read-tree` fail halfway through rewriting the worktree.

`arms/` becomes `arms-old` rather than moving into place, because the incoming
repo has an `arms/` of its own — the templates — and the old directory holds
rendered instances that the new `02-make-arms.sh` will regenerate. Keep it until
the new ones are validated, then delete it.

## Deploy and re-render

```sh
# on your Mac
cd ~/path/to/gvpn-8408
make hooks                   # pre-commit secret scan, once per clone
./tools/scan-secrets.sh --tracked    # nothing should have leaked already
make push
```

```sh
# back on the VM
cd ~/gvpn-8408
ls lib/common.sh Makefile tools/    # the push landed
make status                         # state dir found, no run in progress
make arms                           # render templates -> ~/gvpn-state/arms
```

## Validate before trusting it

Two gates, in this order. Neither is optional — the second is the one that
decides whether any later number means anything.

```sh
# 1. SSH survives a tunnel connect
sudo ./bench/use-arm.sh auto
gnosis_vpn-ctl start-client 30m && gnosis_vpn-ctl connect UK
#   from your Mac, in another terminal:  ssh gvpn-vm 'echo still-here'
gnosis_vpn-ctl disconnect

# 2. the pin takes
sudo ./bench/use-arm.sh pin-planner --count   # must report 1 distinct route
sudo ./bench/use-arm.sh auto --count          # must report many
```

If gate 2 reports many for both, the manual hopr-lib config is not being read.
Check `/etc/systemd/system/gnosisvpn.service.d/30-arm.conf` and that
`~/gvpn-state/arms/pin-planner/hopr.yaml` has real addresses rather than
`0xFILL_ME_IN` — the latter means the node had not onboarded when `make arms` ran.

Then a smoke run:

```sh
make smoke && make report
```

## Clean up

Once a real run has completed on the new layout:

```sh
rm -rf ~/gvpn-state/arms-old
```

## If something goes wrong

Nothing was deleted. `~/gvpn-state/runs` holds every old run, `arms-old` holds the
old rendered arms, and the identity is both in place and backed up. To go back,
`git checkout` the previous kit revision on the VM and move `runs` back to
`bench-runs` — but read `CHANGELOG.md` first, because a run recorded under the old
kit has no `kit_rev` in its manifest and the analyser will report its provenance
as unknown.
