# Running every arm

Six arms, **three studies**. They cannot be one run, and the reason is the same
each time: an arm that changes the node's own state changes it for every other
arm sharing the run.

| Study | Arms | Why separate | Cost |
|---|---|---|---|
| **1 — planner** | `auto` `pin-planner` `no-explore` `narrow` `zero-hop` | — | 3 h to 36 h — your call, see below |
| **2 — return leg** | `pin-cfg-<relay>` `pin-cfg-pinned-<relay>` | needs the channel set trimmed to one relay, which is node-global | trim + one run |
| **3 — restore** | `auto` | confirms the node came back | ~1 h |

Study 1 answers *does pinning help*. Study 2 answers *which leg*, and is only
worth running if study 1 says pinning helps at all. Study 3 is bookkeeping, and
the step people skip.

Everything below assumes `docs/START-HERE.md` is done: kit deployed, identity
backed up, both gates passed.

---

## Why it takes as long as it does

Not the transfers. A 25 MB leg at 5 Mbit/s is ~42 s, so a download-plus-upload
session moves data for ~84 s — but the session costs ~3 min, because:

| | |
|---|---|
| connect + first path draw | 40 s |
| the transfers | 84 s |
| settle, disconnect, cooldown before the next arm | 45 s |
| UDP probe + inter-leg gaps | 20 s |

The cooldown is not padding: without it the next arm inherits the last one's
SURB balancer estimate and path cache, which is the contamination the whole
interleaved design exists to avoid.

**So ~3 min per session is the floor, and everything after that is multiplication:**

```
wall clock  =  3 min  ×  arms  ×  exits  ×  cycles
```

The 36 h I quoted was `5 arms × 3 exits × 30 cycles` with 60-second timed legs
and 3 reps — 450 sessions. That is a full matrix, not a requirement. Each factor
is yours to cut, and cutting them is not cheating:

| Change | Cost |
|---|---|
| 5 arms → 2 (`auto` + `pin-planner`) | ÷2.5 |
| 3 exits → 1 | ÷3 |
| timed 60 s legs, 3 reps → one 25 MB transfer | ÷2.2 |
| 30 cycles → 10 | ÷3 |

The one to think hardest about is **cycles**, because it is the only one that
buys statistical power rather than coverage. The headline number of this study is
the *floor rate* — what fraction of sessions fall below the threshold — and that
is a tail statistic. At 10 sessions per arm you can see that pinning helps, but
the confidence interval spans most of the plausible range and the report will
say `suggestive, not conclusive`. At 30 you can separate a 10 % floor rate from a
30 % one. Below 20 the report prints a warning on its own.

### Why cutting cycles is different from cutting arms

Arms and exits are coverage: drop one and you learn less, but what you keep is
still true. Cycles are resolution: drop them and what you keep starts lying.

Below **8 sessions per arm** the bootstrap returns nothing at all, so every
confidence interval disappears and the report is left with bare point estimates
from a handful of samples. Below **30** it prints a caveat.

Fabricated runs make it concrete — same simulated effect, same ~1 h 15 m of wall
clock, only the shape differs (`tests/mkrun.py`, scenario `thin` vs a 12-cycle
pair):

| | 5 arms × 5 cycles | 2 arms × 12 cycles |
|---|---|---|
| wall clock | 1 h 18 m | 1 h 15 m |
| sessions per arm | 5 | 12 |
| verdict | *"Too few sessions to separate the arms"* | *"Suggestive but not conclusive: +635% (-13 … +784)"* |
| confidence intervals | none — below the bootstrap's minimum | present, and honest about spanning zero |
| `no-explore` | **−74%** — apparent harm from an arm configured to *help* | not run |

That −74% is the thing to notice. Nothing was misconfigured; five sessions is
simply not enough for a 10th percentile, so one unlucky session inverted the
sign. With five arms you get five chances to draw a headline that is backwards.

There is a second, quieter problem: at five sessions the floor rate can only be
0 %, 20 %, 40 %, 60 %, 80 % or 100 %. The headline number of this whole study
has six possible values, and "20 %" means "one session".

**So spend a fixed budget on cycles before arms.** Two arms and twelve cycles
answers the actual question — does pinning raise the floor — and says clearly
that it needs more data. Five arms and five cycles answers nothing, in five
different directions.

Five arms at five cycles is worth running for exactly one thing: confirming
every arm's config loads, `zero-hop` gets its `--allow-insecure`, and the pin
takes. That is a rig check, and `--profile smoke` does it in ten minutes.

### The ladder

| Config | Wall clock | Sessions/arm | What it answers |
|---|---|---|---|
| `smoke`, 5 arms, 1 exit | ~10 min | 1 | does every arm's config load |
| `quick`, 2 arms, 1 exit | ~25 min | 3 | what is `auto`'s p25 (for the floor) |
| `transfers`, 2 arms, 1 exit, 12 cycles | **~1 h 15 m** | 12 | is there a signal worth chasing |
| `transfers`, 2 arms, 1 exit, 30 cycles | **~3 h 10 m** | 30 | a quotable floor-rate result |
| `transfers`, 5 arms, 1 exit, 30 cycles | ~7 h 50 m | 30 | which lever, one exit |
| `soak`, 5 arms, 3 exits | ~36 h | 60+ | the full matrix, exit as a dimension |

**Start at 3 hours.** Run the two-arm, one-exit, 30-cycle version, read the
verdict, and only spend the 36 hours if the answer turns out to be interesting
enough to argue about.

```sh
make soak STUDY=2026-09-24-transfers-25mb     # ~3 h, detached
```

That study file ships in `studies/`. It sets `--profile transfers`: 30 cycles,
bytes mode, 25 MB each way, one transfer per session. One transfer per session
rather than several is deliberate — the floor rate is computed over *sessions*,
so thirty sessions of one transfer is worth more than ten sessions of three.

Every profile prints its schedule before committing to it:

```sh
make dry STUDY=2026-09-24-transfers-25mb
```

---

## Before any long run: trial, then launch

Two commands. The first proves every arm runs through; the second does it again
and then launches the real thing.

```sh
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --trial-only
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --launch -y
```

or `make preflight STUDY=…` / `make launch STUDY=…`.

**`--trial` is the study shrunk, not a different study.** Same arms, same exits,
same load source, 1 cycle × 5 MB — about 3 minutes for two arms. That matters:
running `--profile smoke` instead would exercise a *different* configuration,
which is how a rehearsal passes and the real run fails on its first cycle.

A trial's manifest records `trial: true`, and the analyzer refuses to score it —
the verdict reads `TRIAL RUN — a rehearsal of the pipeline, not a result`, even
when the data shows a large effect. A rehearsal's report cannot be mistaken for
the study's.

What preflight checks, in order, each stage gating the next:

| Stage | Time | Catches |
|---|---|---|
| **A** static | seconds | unrendered arms, placeholders left in, service down, **version not pinned**, `zero-hop` without `--allow-insecure`, planner DEBUG off, policy route missing or pointing at an empty table, disk, a run already in progress, a `pin-cfg-*` arm smuggled into a normal study |
| **B** route gate | ~3 min/arm | an arm whose yaml never loaded — `HoprLibConfig` is `deny_unknown_fields`, so a typo stops the service. Asserts `pin-planner` = 1 route and the baseline > 1. **A baseline of 1 fails the run**: a one-channel node has no path diversity to lose and every comparison would be void. |
| **C** trial | ~1 min/arm | data actually moving: endpoints reachable through the tunnel, every arm producing a usable session, the report rendering |
| **D** calibrate | ~25 min | runs the **baseline alone** and writes its p25 into the study file as `GVPN_FLOOR_MBPS`. Baseline-only on purpose — nothing about the pinned arms can influence the threshold they are judged against. Skipped if the study already declares one. |
| **E** launch | — | `--detach`, survives your SSH closing |

It exits non-zero at the first hard failure, so `--launch` cannot fire after a
failed check.

Then walk away:

```sh
make status                     # is it still going
make report                     # when it finishes
```

---

## Study 1 — the planner arms

All five share one interleaved run. None of them touches channels, the identity
or anything else the next arm inherits, so interleaving is safe and the paired
per-cycle comparison holds.

`zero-hop` is included, with one caveat: it needs the service running with
`--allow-insecure`, and it sends traffic with **no relay**, so the exit sees this
VM's own IP. Fine for a test box, not for anything you care about. Leave it out
by dropping it from `GVPN_ARMS` if that matters.

```sh
ssh gvpn-vm && cd ~/gvpn-8408

# the flag zero-hop needs — already set if gvpn.conf had GVPN_ALLOW_INSECURE=1
systemctl show gnosisvpn -p ExecStart | grep -o -- --allow-insecure || \
  echo "zero-hop will fail: re-run setup/00-vm-setup.sh --allow-insecure"
```

Pick the scale from the ladder above. The three-hour version ships ready:

```sh
# studies/2026-09-24-transfers-25mb.conf   — 2 arms, 1 exit, 30 × 25 MB
GVPN_PROFILE=transfers
GVPN_ARMS="auto pin-planner"
GVPN_DESTINATIONS="UK"
GVPN_PIN_VERSION=<exact version from `gnosis_vpn-ctl info`>
GVPN_FLOOR_MBPS=<auto's p25 from the quick run>
```

The full matrix is the same file with more arms and more exits — and `soak`
instead of `transfers`, which switches to timed legs and three reps per session:

```sh
# studies/2026-09-22-pin-vs-auto.conf      — 5 arms, 3 exits, ~36 h
GVPN_PROFILE=soak
GVPN_ARMS="auto pin-planner no-explore narrow zero-hop"
GVPN_DESTINATIONS="UK USA India"
```

```sh
make push
```

On the VM — **always dry-run first**, it prints the schedule and the wall clock
before anything starts:

```sh
make dry   STUDY=2026-09-24-transfers-25mb
make soak  STUDY=2026-09-24-transfers-25mb
make status                     # while it runs
make report                     # when it finishes
make publish STUDY=2026-09-24-transfers-25mb
```

**Before quoting anything:** `distinct routes` must read `1.0` for `pin-planner`
and many for `auto`. The report voids itself if not, but know why.

### What to read

| Comparison | Answers |
|---|---|
| `auto` vs `pin-planner` | does pinning raise the floor at all? If no, stop — the hypothesis is wrong and studies 2–3 answer nothing. |
| `auto` vs `no-explore` | is it specifically the 10% random return draws? A one-line fix if so. |
| `pin-planner` vs `narrow` | how much diversity survives? `narrow` close to `pin-planner` means a shippable setting. |
| `zero-hop` vs the rest | the ceiling. How much of the gap is the relay at all, versus entry/exit/WireGuard. |

---

## Study 2 — the return leg

**Only if study 1 showed a gap.** This trims the node to one channel, which
takes on-chain transactions and a grace period, and `auto` is not meaningful
while it is trimmed.

### 2a — render the pair

Pick the relay from study 1's route list — one that carried traffic and
performed around the median, not the best one, or you bias the arm upward.

```sh
sudo grep -o 'path=[^ ]*' /var/log/gnosisvpn/gnosisvpn.log | sort -u | head
make arms   # or: sudo -E ./setup/02-make-arms.sh --pin-relay 0xRELAY
```

That renders **two** arms, and the pair is the experiment:

```
pin-cfg-0xRELAY…          allowlist held, forward pinned by topology, return free
pin-cfg-pinned-0xRELAY…   the same, plus max_cached_paths = 1 — return pinned too
```

Both carry the allowlist deliberately. Without it the strategy would reopen the
channels you are about to close, during the other arm's sessions, un-trimming the
node midway with nothing in the data marking where.

### 2b — install the allowlist, then close

Order matters. Allowlist first, so nothing reopens behind you.

```sh
sudo ./bench/use-arm.sh pin-cfg-0xRELAY…          # installs the allowlist

sudo -E ./tools/close-channels.py --keep 0xRELAY          # plan only
sudo -E ./tools/close-channels.py --keep 0xRELAY --send   # initiate
```

Wait out the grace period — `--list` prints when each is ready — then:

```sh
sudo -E ./tools/close-channels.py --list
sudo -E ./tools/close-channels.py --finalize --send
```

The first close is sent alone and verified on-chain before the rest. If that
canary fails, nothing else was touched; read `/var/log/gnosisvpn/channel-close.log`.

### 2c — confirm the trim, then run

```sh
sudo -E ./tools/close-channels.py --list     # should show one channel
sudo ./bench/use-arm.sh pin-cfg-0xRELAY… --count          # must read 1
sudo ./bench/use-arm.sh pin-cfg-pinned-0xRELAY… --count   # must read 1
```

Both read 1 — that is expected and is not a failure. They both have one *forward*
path because the node has one channel. What differs is the return draw, which the
route count does not show.

A study file of its own:

```sh
# studies/2026-10-01-return-leg.conf
GVPN_ARMS="pin-cfg-0xRELAY… pin-cfg-pinned-0xRELAY…"
GVPN_DESTINATIONS="UK USA India"
GVPN_PIN_VERSION=<same version as study 1>
GVPN_FLOOR_MBPS=<same threshold as study 1>
```

```sh
make soak STUDY=2026-10-01-return-leg
make report
make publish STUDY=2026-10-01-return-leg
```

Keep the version and the floor identical to study 1, or the two studies are not
comparable and the whole point is lost.

### What to read

Both arms have one forward path. The only difference is whether the return draw
is collapsed.

- **`pin-cfg-pinned` ≫ `pin-cfg`** — the return leg is where the damage is. That
  is the finding, and it points at the SURB draw rather than at relay capacity.
- **They are the same** — the forward leg was doing the work, and pinning the
  return adds nothing.
- **Both ≈ study 1's `pin-planner`** — consistent, and worth stating: it means
  the channel-level trim and the planner-level pin reach the same place.

---

## Study 3 — put the node back

The step people skip. While trimmed, this node is not a normal client, and
anything measured on it later is measured on a one-channel node.

```sh
sudo ./bench/use-arm.sh auto        # removes the allowlist
```

The strategy reopens channels toward `target_open_channels` on its own. Watch:

```sh
watch -n 60 'sudo -E ./tools/close-channels.py --list'
```

Once the count is back to normal, a short confirmation run:

```sh
sudo -E ./bench/gvpn-bench.sh --profile quick
make report
```

Compare its `auto` against study 1's `auto`. They should agree. If they do not,
the node has not recovered and anything you run next is suspect.

---

## The whole sequence

```sh
# Study 1 — planner arms                                       ~36 h
make soak STUDY=2026-09-22-pin-vs-auto
make report && make publish STUDY=2026-09-22-pin-vs-auto

#   → if pinning showed no gap, STOP. Studies 2-3 answer nothing.

# Study 2 — return leg                                         ~1 h + ~36 h
make arms                                          # renders the pin-cfg pair
sudo ./bench/use-arm.sh pin-cfg-0xRELAY…           # allowlist first
sudo -E ./tools/close-channels.py --keep 0xRELAY --send
#   wait out the grace period
sudo -E ./tools/close-channels.py --finalize --send
sudo ./bench/use-arm.sh pin-cfg-0xRELAY… --count   # must read 1
make soak STUDY=2026-10-01-return-leg
make report && make publish STUDY=2026-10-01-return-leg

# Study 3 — restore                                            ~1 h
sudo ./bench/use-arm.sh auto
#   wait for the channel count to recover
sudo -E ./bench/gvpn-bench.sh --profile quick && make report
```

## Things that will bite

| | |
|---|---|
| Mixing `auto` into study 2 | The bench warns for 10s. On a one-channel node `auto` is not auto. |
| Different `GVPN_PIN_VERSION` between studies | Silently compares versions instead of routing modes. The manifest records what ran — but only afterwards. |
| Re-picking `GVPN_FLOOR_MBPS` per study | Makes the headline number whatever you wanted. Freeze it at study 1. |
| Picking the best relay for `pin-cfg` | Biases the arm upward. Pick a median performer. |
| Forgetting study 3 | Every later measurement is on a one-channel node. |
| Re-rendering arms mid-study | Changes what the remaining cycles measure. Each run records `kit_rev`; a study that spans a change should be restarted. |
