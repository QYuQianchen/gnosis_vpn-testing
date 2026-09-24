# Configure and run

Start to finish. Every field you have to supply, in the order you hit it, and
the three commands that run the thing.

**Short version:** there is exactly **one** field you must type by hand
(`GVPN_DESTINATION`, and only if your exit is not called `UK`), one you set with
a flag rather than typing, and one the kit measures for you. Everything else has
a working default.

---

## 0 · What you need first

| | |
|---|---|
| A VM under test | Contabo Ubuntu, ≥ 4 vCPU, ≥ 8 GB RAM, ≥ 40 GB disk. Planner DEBUG logging is hungry. |
| Console access to it | Contabo VNC. A full-tunnel VPN can eat your SSH; this is the way back in. |
| The kit on it | `docs/START-HERE.md` — unpack, `00-vm-setup.sh`, onboard, back up the identity. |
| An SSH alias | `gvpn-vm` in `~/.ssh/config` on your Mac. `make push` and every command below uses that name. |

```
# ~/.ssh/config on your Mac
Host gvpn-vm
    HostName  ⟨the VM's public IP⟩
    User      deploy
    IdentityKey ~/.ssh/⟨your key⟩
```

No faucet codes are needed. No shipped arm re-onboards.

---

## 1 · `gvpn.conf` — machine defaults, edited once

This file describes **the VM**, not any one experiment. Edit it on your Mac,
`make push`.

### Check one field

```sh
# on the VM — what your config.toml actually calls its exits
gnosis_vpn-ctl destinations
```

```sh
# gvpn.conf
GVPN_DESTINATION=UK        # ← must be a name that command printed
```

If yours are named differently, this is the one value you type. `make arms`
fails loudly on a name that is not in `config.toml`, so a typo is caught rather
than silently producing a run against nothing.

### Leave these unless you have a reason

| Field | Default | Change it when |
|---|---|---|
| `GVPN_CHANNEL` | `stable` | you want `snapshot` or `experimental`. This can move the client across release lines, so available networks change with it. |
| `GVPN_NETWORK` | `jura-prod` | testing `jura-dev` or `piz-palu-dev`. Must match the channel. |
| `GVPN_PIN_VERSION` | *(empty)* | **leave empty here** — it belongs in the study file, per experiment (see §2). |
| `GVPN_ALLOW_INSECURE` | `1` | only `zero-hop` needs it. Harmless otherwise. |
| `GVPN_TARGET` | `url` | you have a second VPS for iperf3. Not required — `url` measures both directions, loss and jitter from the one VM. |
| `GVPN_DL_URL` / `GVPN_UL_URL` | Cloudflare | you would rather not depend on a third party. **Verify both from the VM first** — §5. |
| `GVPN_PING_TARGET` | `1.1.1.1` | your network blocks it. |
| `GVPN_LOG_SIZE` / `GVPN_LOG_KEEP` | `200M` / `20` | small disk. ~100 MB/hour of planner DEBUG. |

---

## 2 · `studies/<name>.conf` — one file per experiment

One already ships, sized for a first real run — two arms, one exit, ~3 h:

```sh
# studies/2026-09-24-transfers-25mb.conf
GVPN_PROFILE=transfers          # 30 cycles, 25 MB each way, 1 transfer/session
GVPN_ARMS="auto pin-planner"    # the question, and nothing else
GVPN_DESTINATIONS="UK"          # ← same name as §1
GVPN_DL_BYTES=25M
GVPN_UL_BYTES=25M
GVPN_REPS=1

GVPN_PIN_VERSION=               # ← set by --pin-current in §4
GVPN_FLOOR_MBPS=                # ← measured by preflight in §4
```

**Leave the last two empty.** Step 4 fills both in and writes them back to this
file, so the study records what actually ran. Commit it afterwards — the report
cites a tracked value rather than something typed once and forgotten.

To run a different shape, copy the file and change the date in its name. Wall
clock is `~3 min × arms × exits × cycles`:

```sh
GVPN_ARMS="auto pin-planner no-explore narrow zero-hop"   # 5 arms → ~8 h
GVPN_DESTINATIONS="UK USA India"                          # ×3 exits → ~24 h
```

Do not edit a study file once its run has started. An edited study is one whose
arms were not all measured the same way, and nothing in the output would say so.

---

## 3 · Deploy

```sh
# on your Mac, from your clone
make push
```

Then, once per node:

```sh
ssh gvpn-vm && cd ~/gvpn-8408
sudo -E ./setup/02-make-arms.sh        # renders arm templates with this node's addresses
```

`make push` is refused while a run is in progress — a deploy rewrites script
files in place and bash reads a script as it executes.

---

## 4 · The three commands

```sh
ssh gvpn-vm && cd ~/gvpn-8408
```

### a. Pin the version and rehearse — ~10 min

```sh
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb \
     --pin-current --trial-only
```

`--pin-current` writes the installed version into the study file, so you never
transcribe a string like `2026.09.17+build.134506` by hand. `--trial-only` runs
your study at 1 cycle × 5 MB — **same arms, same exits, same load source** — and
stops. It is a rehearsal of *this* study, not a smaller different one.

Expect:

```
A  static checks
  PASS  arm 'auto' is rendered
  PASS  pinned the study at the installed version 2026.09.17+build.134506
  PASS  planner DEBUG logging is on
  PASS  policy route present and table 200 is non-empty
B  per-arm route gate
  PASS  auto drew 14 routes (free, as designed)
  PASS  pin-planner drew 1 route (pinned, as designed)
C  TRIAL
  PASS  auto completed 1/1 session(s) with data
  PASS  pin-planner completed 1/1 session(s) with data
  PASS  report renders
```

Nothing after a failure runs, so a red line means stop and read it — each one
says what to do.

### b. Calibrate and launch — ~25 min, then ~3 h unattended

```sh
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --launch -y
```

Re-runs the checks, then runs the **baseline arm alone** for 8 cycles and writes
its p25 into the study as `GVPN_FLOOR_MBPS`. Baseline-only on purpose: nothing
about the pinned arm can influence the threshold it is judged against. Then it
launches detached and returns — close your laptop.

### c. Read it

```sh
make status                              # still going?
make report                              # when it finishes
make publish STUDY=2026-09-24-transfers-25mb
```

`results/2026-09-24-transfers-25mb/report.md` is what goes into the issue.

---

## 5 · Verify before the long run

One check I could not run from where the kit was built, so it is yours. With the
tunnel up on the VM:

```sh
curl -s -o /dev/null -w '%{http_code}\n' \
     "https://speed.cloudflare.com/__down?bytes=1000000"
head -c 1000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' \
     --data-binary @- "https://speed.cloudflare.com/__up"
```

Both must print `200`. A three-hour run against a URL that 404s produces a
directory full of nothing. (Preflight's trial catches this too — this is just
the ten-second version.)

And the one that protects your access:

```sh
ip rule show | grep 200 && ip route show table 200   # BOTH must be non-empty
gnosis_vpn-ctl connect UK
#   from a third machine:  ssh ⟨user⟩@⟨VM IP⟩ 'echo still-here'
gnosis_vpn-ctl disconnect
```

Preflight checks the route exists, but only you can confirm SSH actually
survives. A rule pointing at an empty table is the worst state — it looks
configured and protects nothing.

---

## Every field, in one table

| Field | Where | You provide | If wrong |
|---|---|---|---|
| `gvpn-vm` | `~/.ssh/config`, Mac | **yes** | `make push` fails immediately |
| `GVPN_DESTINATION` | `gvpn.conf` | **yes, if not `UK`** | `make arms` fails loudly |
| `GVPN_ARMS` | study file | choose the scale | more arms = more hours |
| `GVPN_DESTINATIONS` | study file | same name as above | dry-run shows the cost |
| `GVPN_PIN_VERSION` | study file | `--pin-current` | **silently compares versions, not routing modes** |
| `GVPN_FLOOR_MBPS` | study file | preflight measures it | **silently makes the headline whatever you wanted** |
| everything else | `gvpn.conf` | defaults work | — |

The last two are the ones that produce a plausible-but-meaningless result rather
than failing. Preflight refuses to launch without the first and measures the
second, which is the whole reason it exists.

---

## When it fails

| Symptom | What it is |
|---|---|
| `FAIL the study sets no GVPN_PIN_VERSION` | add `--pin-current`, or pick one with `05-set-version.sh --list` |
| `FAIL auto drew 1 route` | the node holds one channel — the baseline has no diversity to lose and every comparison would be void |
| `FAIL pin-planner drew N routes` | the manual hopr config is not being read; check `/etc/systemd/system/gnosisvpn.service.d/30-arm.conf` |
| `NO RESULT: no 'candidate path' lines` | planner DEBUG is off. Not "one route" — nothing was counted |
| `FAIL policy route missing` | a connect may take your SSH. Fix before going further, console open |
| `FAIL a run is already in progress` | `make status`; clear the lock only if it is stale |
| `unsubstituted placeholders` | the node had not onboarded when `make arms` ran. Re-run it |
| Report says `THE PIN DID NOT TAKE` | the run compared `auto` with itself. Discard it |
| Report says `TRIAL RUN` | you are reading a rehearsal, not the study |
