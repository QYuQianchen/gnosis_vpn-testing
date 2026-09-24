# Start here

The one path from "I have the tarball" to "I have a result on gvpn-vm".

Every block is labelled **MAC** or **VM**. `⟨fill in⟩` marks the three things only
you can supply. Nothing else needs a decision.

---

## What you fill in

| # | What | Where | Notes |
|---|---|---|---|
| 1 | SSH alias `gvpn-vm` | `~/.ssh/config` on your Mac | Already working if `ssh gvpn-vm` connects. Every command below uses that name. |
| 2 | Backup passphrase | typed once, at step 2 | Stored nowhere. Put it in your password manager **before** you type it. |
| 3 | `GVPN_FLOOR_MBPS` | `studies/…​.conf`, at step 7 | You cannot pick this yet — step 7 measures it. |

No faucet codes are needed. No shipped arm re-onboards — `pin-cfg-*` used to and
no longer does; it needs a manual channel change on your Safe instead, and says
so when you render it.

---

## 0 · VM — where are you?

```sh
ssh gvpn-vm
cd ~/gvpn-8408

ls lib/common.sh Makefile tools/ 2>/dev/null && echo "NEW KIT PRESENT" || echo "OLD KIT"
ls ~/gvpn-state/run.lock 2>/dev/null && echo "RUN IN PROGRESS — stop here"
gnosis_vpn-ctl -o plain status | head -1
```

- **"OLD KIT"** → do steps 1–4.
- **"NEW KIT PRESENT"** → skip to step 5.
- **A run in progress** → wait for it. Deploys are refused while one is going.

---

## 1 · MAC — put the new kit in your clone

```sh
cd ⟨parent directory of your gvpn-8408 clone⟩
tar xzf ~/Downloads/gvpn-8408-kit.tar.gz

cd gvpn-8408
git status --short                 # this is the whole diff — read it
git diff gvpn.conf studies/        # did it revert settings of yours? re-apply if so
make hooks
make test                          # both suites must pass before you push
```

---

## 2 · VM — back up the funded identity

Do this before anything touches the node. Re-onboarding costs a faucet code and
an hour; this costs a minute.

```sh
ssh gvpn-vm
umask 077
mkdir -p ~/gvpn-state/identity-backup

read -rsp 'Backup passphrase: ' BK; echo      # ⟨fill in⟩ — save it first
OUT=~/gvpn-state/identity-backup/identity-$(date -u +%Y%m%d).tar.gz.enc

sudo systemctl stop gnosisvpn
sudo tar czf - -C /var/lib/gnosisvpn .config \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -pass fd:3 -out "$OUT" 3< <(printf %s "$BK")
sudo systemctl start gnosisvpn

openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
      -pass fd:3 -in "$OUT" 3< <(printf %s "$BK") | tar tzf -
unset BK
```

The listing must include `.config/gnosisvpn-hopr.id`. Then **from your Mac**:

```sh
scp gvpn-vm:gvpn-state/identity-backup/identity-*.enc ⟨somewhere safe⟩
```

A backup living only on the machine it protects is not a backup.

---

## 3 · VM — clear anything blocking the deploy

`arms/` and `bench-runs/` were written by `sudo` runs, so they are root-owned and
the deploy (which runs as you) cannot write into them.

```sh
ssh gvpn-vm && cd ~/gvpn-8408
ME=$(id -un); STATE=$HOME/gvpn-state
mkdir -p "$STATE"/{runs,arms,secrets,identity-backup}
chmod 700 "$STATE/secrets" "$STATE/identity-backup"

[ -d bench-runs ] && { sudo find bench-runs -maxdepth 1 -mindepth 1 \
                          -exec mv -t "$STATE/runs/" {} + ; sudo rmdir bench-runs; }
[ -d arms ]              && sudo mv arms              "$STATE/arms-old"
[ -f faucet-codes ]      && sudo mv faucet-codes      "$STATE/secrets/"
[ -f faucet-codes.used ] && sudo mv faucet-codes.used "$STATE/secrets/"

sudo find . -path ./.git -prune -o ! -user "$ME" -exec chown -R "$ME": {} +
sudo chown -R "$ME": "$STATE"

find . -path ./.git -prune -o ! -user "$ME" -print 2>/dev/null
```

**That last command must print nothing.** It is the gate for step 4.

---

## 4 · MAC — push, then re-arm the hook

```sh
cd ⟨your gvpn-8408 clone⟩
git add -A
git commit -m "kit: routing-mode A/B study"
make push
```

```sh
ssh gvpn-vm && cd ~/gvpn-8408
./setup/06-git-deploy.sh          # no sudo — regenerates the deploy hook
make status
```

The hook is generated at install time, not tracked, so its fixes are not live
until this runs.

---

## 5 · VM — check what your node actually runs

This decides what "auto" means on your machine, and every arm inherits it.

```sh
sed -n '/\[connection.path_planner\]/,/^\[/p' /etc/gnosisvpn/config.toml
```

Empty is fine (your node uses the client preset). If it sets
`min_paths_anonymity_floor` or anything else, that is your real control — and the
arms pick it up automatically. Just note what it said.

```sh
make arms
ls ~/gvpn-state/arms
grep safe_address ~/gvpn-state/arms/pin-planner/hopr.yaml
```

That address must be real, not `0xFILL_ME_IN`. Placeholder means the node had not
onboarded when `make arms` ran — wait for `Ready` and re-run it.

---

## 6 · VM — the two gates

Neither is optional. The second decides whether any later number means anything.

### Gate 1 — SSH survives the tunnel

```sh
sudo ./bench/use-arm.sh auto
ip rule show | grep 200          # both must be NON-EMPTY
ip route show table 200          # a rule with an empty table protects nothing

gnosis_vpn-ctl start-client 30m
gnosis_vpn-ctl status            # wait for Ready
gnosis_vpn-ctl connect ⟨your destination, e.g. UK⟩
```

From your Mac, **in a second terminal**: `ssh gvpn-vm 'echo still-here'`

Then on the VM: `gnosis_vpn-ctl disconnect`

If that SSH hangs you are locked out — recover via Contabo's VNC console and fix
`/usr/local/sbin/gvpn-ssh-bypass.sh` before going further.

### Gate 2 — the pin takes

```sh
sudo ./bench/use-arm.sh pin-planner --count      # must report 1 route
sudo ./bench/use-arm.sh auto        --count      # must report many
```

Each takes several minutes and prints a line per state change. Both reporting
many means the manual config is not loading — check
`/etc/systemd/system/gnosisvpn.service.d/30-arm.conf`. Do not continue until
`pin-planner` reads 1.

---

## 7 · VM — a short run, to set the floor

```sh
make smoke        # ~6 min, rig check
make report

sudo -E ./bench/gvpn-bench.sh --profile quick    # ~35 min
make report
```

Read **`auto`'s p25** off that second report. That is your floor threshold —
`⟨fill in⟩` #3. On your Mac:

```sh
# studies/2026-09-22-pin-vs-auto.conf
GVPN_FLOOR_MBPS=⟨auto's p25 from the quick run⟩
GVPN_PIN_VERSION=⟨the exact version from `gnosis_vpn-ctl info`⟩
GVPN_DESTINATIONS="⟨one or more exits, e.g. UK USA India⟩"
```

```sh
make push
```

Pick the threshold **now**, from the baseline, before seeing the pinned arm.
Choosing it afterwards makes the headline number whatever you want it to be.

---

## 8 · VM — the real run

```sh
ssh gvpn-vm && cd ~/gvpn-8408

GVPN_STUDY=2026-09-22-pin-vs-auto ./bench/gvpn-bench.sh --profile soak --dry-run
make soak STUDY=2026-09-22-pin-vs-auto
```

`--dry-run` prints the schedule and wall clock first. Three exits multiplies it
by three — check before committing 36 hours.

While it runs, deploys are blocked:

```sh
make status
tail -f ~/gvpn-state/runs/⟨newest⟩/run.log
cat ~/gvpn-state/runs/⟨newest⟩/deadman.log      # empty is good
```

---

## 9 · The result

```sh
ssh gvpn-vm && cd ~/gvpn-8408
make report
make publish STUDY=2026-09-22-pin-vs-auto
```

On your Mac:

```sh
cd ⟨your clone⟩
git pull vm main
git add results/ && git commit -m "results: pinned vs auto"
make push
```

`results/2026-09-22-pin-vs-auto/report.md` is what goes into the issue.

That is study 1 — the five planner arms. The `pin-cfg-*` pair needs the node's
channel set trimmed first, which is node-global and cannot share a run with
anything else. **`docs/running-all-arms.md`** sequences all six arms as the three
studies they have to be, including how to put the node back afterwards.

Before quoting any number from it, check the **distinct routes** column reads
`1.0` for `pin-planner`. If it does not, the report says so itself and refuses to
claim a result — but it is worth knowing why.

---

## If something stalls

| Symptom | What it is |
|---|---|
| `use-arm.sh --count` sits silently | Not a hang. Up to 5 min of polling; it prints each state change. |
| `Permission denied` on `arms/…` during push | Step 3 was skipped, or run on the Mac. `make fix-perms` on the VM. |
| Push rejected, "run in progress" | A soak is going. `make status`; `rm ~/gvpn-state/run.lock` only if it is stale. |
| `0xFILL_ME_IN` in an arm's yaml | Node had not onboarded when `make arms` ran. Re-run it. |
| Report says "THE PIN DID NOT TAKE" | Gate 2 regressed mid-run. The run measured `auto` against itself; discard it. |
