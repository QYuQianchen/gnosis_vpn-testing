# Runbook: from here to a running study

Every block says which machine it runs on. Do them in order — step 3 must happen
before step 4, and the two gates in step 7 must both pass before step 9.

`gvpn-vm` below is your SSH alias; `~/gvpn-8408` is the kit on both machines.

---

## 1 · MAC — get the new kit into your clone

```sh
cd ~/path/to/parent-of-your-clone      # the directory CONTAINING gvpn-8408
tar xzf ~/Downloads/gvpn-8408-kit.tar.gz

cd gvpn-8408
git status --short                     # review: this overwrote tracked files
make hooks                             # pre-commit secret scan, once per clone
./tools/scan-secrets.sh --tracked      # must say nothing
```

Do not commit yet. The VM has to be fixed first, or the push bounces again.

---

## 2 · VM — back up the funded identity

Irreplaceable, and cheap. Do it before anything else touches the box.

```sh
ssh gvpn-vm
umask 077
mkdir -p ~/gvpn-state/identity-backup

read -rsp 'Backup passphrase: ' BK; echo
read -rsp 'Again: '            BK2; echo
[ "$BK" = "$BK2" ] || echo "MISMATCH - start over"

OUT=~/gvpn-state/identity-backup/identity-$(date -u +%Y%m%d).tar.gz.enc

sudo systemctl stop gnosisvpn
sudo tar czf - -C /var/lib/gnosisvpn .config \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -pass fd:3 -out "$OUT" 3< <(printf %s "$BK")
sudo systemctl start gnosisvpn

# verify by decrypting what was just written
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
      -pass fd:3 -in "$OUT" 3< <(printf %s "$BK") | tar tzf -
unset BK BK2
```

The listing must include `.config/gnosisvpn-hopr.id`. Then, **from your Mac**:

```sh
scp gvpn-vm:gvpn-state/identity-backup/identity-*.enc ~/secure-place/
```

A backup that lives only on the machine it protects is not a backup.

---

## 3 · VM — clear what is blocking the deploy

This is what the `Permission denied` on `arms/_pin-cfg` is about: `arms/` and
`bench-runs/` were written by `sudo` runs, so they are root-owned, and the deploy
runs as you.

```sh
ssh gvpn-vm
cd ~/gvpn-8408

pgrep -af gvpn-bench.sh                          # must print nothing
ME=$(id -un); STATE=$HOME/gvpn-state

echo "== blocking paths =="
find . -path ./.git -prune -o ! -user "$ME" -print 2>/dev/null | head

mkdir -p "$STATE"/{runs,arms,secrets,identity-backup}
chmod 700 "$STATE/secrets" "$STATE/identity-backup"

[ -d bench-runs ] && { sudo find bench-runs -maxdepth 1 -mindepth 1 \
                          -exec mv -t "$STATE/runs/" {} + ; sudo rmdir bench-runs; }
[ -d arms ]              && sudo mv arms              "$STATE/arms-old"
[ -f faucet-codes ]      && sudo mv faucet-codes      "$STATE/secrets/"
[ -f faucet-codes.used ] && sudo mv faucet-codes.used "$STATE/secrets/"

sudo find . -path ./.git -prune -o ! -user "$ME" -exec chown -R "$ME": {} +
sudo chown -R "$ME": "$STATE"
chmod 600 "$STATE"/secrets/* 2>/dev/null

echo "== must print nothing =="
find . -path ./.git -prune -o ! -user "$ME" -print 2>/dev/null
```

The last command printing nothing is the gate for step 4. Nothing was deleted:
the old rendered arms are at `~/gvpn-state/arms-old`.

---

## 4 · MAC — commit and push

```sh
cd ~/path/to/gvpn-8408
git add -A
git commit -m "restructure: state dir, arm templates, verdict-first report"
make push                              # origin, then vm
```

If it still bounces, read the message: a run in progress (`run.lock`) and a
foreign-owned path give different explanations.

---

## 5 · VM — reinstall the deploy hook

The hook is generated at install time, so the guards that just arrived in the
repo are not live until this runs. Do it once.

```sh
ssh gvpn-vm
cd ~/gvpn-8408
./setup/06-git-deploy.sh               # no sudo
make status                            # state dir found, no run in progress
```

---

## 6 · VM — render the arms

```sh
make arms
ls ~/gvpn-state/arms                   # auto narrow no-explore pin-planner zero-hop
grep safe_address ~/gvpn-state/arms/pin-planner/hopr.yaml
```

That address must be real, not `0xFILL_ME_IN`. If it is the placeholder, the node
had not onboarded when this ran — wait for `Ready` and re-run `make arms`.

---

## 7 · VM — the two gates

**Neither is optional.** Gate 2 decides whether any later number means anything.

### Gate 1 — SSH survives a tunnel connect

```sh
sudo ./bench/use-arm.sh auto

ip rule show | grep 200                # both of these must be NON-EMPTY
ip route show table 200                # a rule with an empty table protects nothing

gnosis_vpn-ctl start-client 30m
gnosis_vpn-ctl status                  # wait for Ready
gnosis_vpn-ctl connect UK
```

From your Mac, in a **second terminal**:

```sh
ssh gvpn-vm 'echo still-here'
```

Then back on the VM: `gnosis_vpn-ctl disconnect`

If that SSH hangs, you have locked yourself out — recover via Contabo's VNC
console and fix `/usr/local/sbin/gvpn-ssh-bypass.sh` before going further.

### Gate 2 — the pin actually takes

```sh
sudo ./bench/use-arm.sh pin-planner --count      # must report 1 distinct route
sudo ./bench/use-arm.sh auto --count             # must report many (5-20)
```

Both reading many means the manual hopr-lib config is not being read — check
`/etc/systemd/system/gnosisvpn.service.d/30-arm.conf`. Do not proceed until
`pin-planner` reads 1.

---

## 8 · VM — smoke, then a quick run to set the floor

```sh
make smoke                             # ~6 min, 1 cycle, rig check
make report
```

Then a real signal check, whose only job is to give you a floor threshold:

```sh
sudo -E ./bench/gvpn-bench.sh --profile quick    # ~35 min, 3 cycles
make report
```

Read `auto`'s **p25** off that report and put it in the study file, on your Mac:

```sh
# studies/2026-09-22-pin-vs-auto.conf
GVPN_FLOOR_MBPS=<auto's p25 from the quick run>
```

```sh
make push                              # so the VM has the same study file
```

Choosing the threshold now, from the baseline, before seeing the pinned arm, is
what stops the headline number being whatever you wanted it to be.

---

## 9 · VM — the soak

```sh
ssh gvpn-vm
cd ~/gvpn-8408

# see the schedule and wall clock before committing 36 hours
GVPN_STUDY=2026-09-22-pin-vs-auto ./bench/gvpn-bench.sh --profile soak --dry-run

make soak STUDY=2026-09-22-pin-vs-auto
```

While it runs (deploys are blocked until it finishes):

```sh
make status
tail -f ~/gvpn-state/runs/<id>/run.log
cat ~/gvpn-state/runs/<id>/deadman.log     # empty is good
```

---

## 10 · When it finishes — the report

```sh
ssh gvpn-vm
cd ~/gvpn-8408
make report                                     # floor comes from the manifest
make publish STUDY=2026-09-22-pin-vs-auto       # into results/ to commit
```

Then on your Mac:

```sh
cd ~/path/to/gvpn-8408
git pull vm main                                # or scp the results directory
git add results/ && git commit -m "results: pinned vs auto, 3 exits"
make push
```

`results/2026-09-22-pin-vs-auto/report.md` is what goes into the issue.

---

## Quick reference

| | |
|---|---|
| where the kit lives | `~/gvpn-8408` (both machines) |
| where runs, arms and secrets live | `~/gvpn-state` (VM only, never in git) |
| a run is in progress | `~/gvpn-state/run.lock` exists; deploys blocked |
| stale lock after a crash | `rm ~/gvpn-state/run.lock` |
| what everything does | `make help` |
