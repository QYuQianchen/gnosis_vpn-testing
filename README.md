# #8408 benchmark kit — runbook

Pinned vs. automatic path finding on Gnosis VPN, on a clean Contabo Ubuntu VM.

## Layout

Two trees, and the split between them is the whole design: **the repo holds what
re-creates an experiment; the state directory holds what an experiment produces
or what identifies this node.** Nothing valuable is inside the worktree, because
a deploy rewrites the worktree.

```
gvpn-8408/                      the repo — safe to force-checkout at any moment
  Makefile                      the commands you'd otherwise retype
  CHANGELOG.md                  what changed between runs; a result cites a kit rev
  gvpn.conf                     defaults: channel, network, version, load source
  studies/<date>-<name>.conf    one tracked file per experiment, named in its report
  arms/<name>/                  arm TEMPLATES — prose, hop count, planner body.
                                No addresses, so they are tracked and diffable.
  lib/common.sh                 kit root, state dir, config loading — sourced by all
  setup/00-vm-setup.sh          prepare the VM under test          [VM, root]
       01-iperf-server.sh       far-end load generator             [optional 2nd VPS]
       02-make-arms.sh          render templates into the state dir [VM, root]
       03-fetch-sources.sh      clone the pinned sources           [optional]
       04-build-patched.sh      build from source                  [Phase 4 only]
       05-set-version.sh        switch / pin the client build
       06-git-deploy.sh         make the VM a git push target      [once, on the VM]
  bench/use-arm.sh              install one arm by hand; --count checks the pin took
        gvpn-bench.sh           the interleaved A/B runner
        gvpn-analyze.py         the report: verdict, tables, --markdown for the issue
  tools/scan-secrets.sh         refuses to commit an address or peer ID
        install-hooks.sh        wires it in as pre-commit (once per clone)
  tests/run-analyze-tests.sh    checks the report against fabricated runs
  results/<study>/              COMMITTED: report.md, summary.csv, manifest.json
  docs/START-HERE.md            the single path from tarball to result — begin here
       configuration.md         every value you have to provide, and why
       upgrading.md             what to do for each new version of the kit
       RUN-THE-TEST.md          every field to configure, and the 3 commands
       running-all-arms.md      all six arms, as the three studies they have to be
       runbook-now.md           the ordered path from here to a running study
       plan.md deploy.md dev-workflow.md migration.md
```

```
~/gvpn-state/                   never tracked, never inside the worktree
  runs/                         raw output — GBs of planner DEBUG logging
  arms/<name>/                  RENDERED arms, carrying safe + module addresses
  secrets/                      faucet codes
  identity-backup/              encrypted identity archives
  run.lock -> runs/<id>         exists while a run is in progress; blocks deploys
```

Three consequences worth knowing before you touch anything:

- **`arms/` in the repo is not runnable.** A template has no `config.toml` and no
  addresses. `make arms` renders it into `~/gvpn-state/arms`, which is what
  `use-arm.sh` and `gvpn-bench.sh` read. Editing a planner setting is a commit,
  which is the point — a silent change invalidates every comparison after it.
- **A push is rejected while a run is in progress.** `push-to-checkout` rewrites
  script files in place and bash reads a script as it executes, so deploying
  mid-soak can corrupt the running bench or swap the analysis under a half-done
  study. Wait, or `rm ~/gvpn-state/run.lock` if it is stale.
- **Run `make hooks` once per clone**, on every machine you commit from. Git does
  not sync hooks, and the realistic way an address reaches the repo is a log
  excerpt pasted into a doc, which no `.gitignore` can catch.

**`docs/RUN-THE-TEST.md` is the configure-and-run path**: every field you provide,
in the order you hit it, and the three commands. There is one field you type by hand.

**`docs/configuration.md` lists every value you have to supply** — there are
three secrets and about a dozen settings, and it flags the two that silently
produce a plausible-but-meaningless result rather than failing.
**`docs/upgrading.md` is the six-step procedure for each new kit version.**

**`gvpn.conf` is the one file to edit for defaults**; a `studies/*.conf` overrides
it for one experiment. The setup scripts source and export both, so the bench
script inherits the same values. Flags still override everything.

**The benchmark needs no build.** The client is installed from APT and every pinned arm is pure
configuration. `03` and `04` exist for reading the code while interpreting results, and for the
optional Phase 4 patch. See `docs/deploy.md`.

## What you need before starting

- The Contabo VM (≥ 4 vCPU, ≥ 8 GB RAM, ≥ 40 GB disk — DEBUG logging is hungry).
- Optionally a second VPS for iperf3 — **not required**. `--target url` runs the whole
  comparison from the one VM, loss and jitter included. See "Load source" below.
- Faucet codes only if you hand-build an arm that re-onboards — no shipped arm does
  (`~/gvpn-state/secrets/faucet-codes`, one per line — outside the repo).
- Console access to the VM (Contabo VNC) as the last resort if the tunnel eats your SSH.

## Order of operations

```bash
# --- on the VM under test -------------------------------------------------
sudo ./setup/00-vm-setup.sh --network jura-prod --allow-insecure

# onboard once, and wait for Ready before anything else
gnosis_vpn-ctl start-client 60m
watch -n5 gnosis_vpn-ctl status

# --- VERIFY SSH SURVIVES A CONNECT. Do not skip this. ---------------------
#   first confirm the policy route is actually in place -- a rule with an empty
#   table is the worst state, because it looks configured and protects nothing:
ip rule show | grep 200 && ip route show table 200     # BOTH must be non-empty
gnosis_vpn-ctl connect UK
#   from a third machine:  ssh <user>@<VM_PUBLIC_IP> 'echo still-here'
gnosis_vpn-ctl disconnect

# --- arms ------------------------------------------------------------------
make arms                                  # renders templates -> ~/gvpn-state/arms
sudo ./bench/use-arm.sh pin-planner --count   # MUST read 1; auto MUST read many

# 10-minute rig check -- no second machine needed
make smoke
make report

# the real run, unattended
make soak STUDY=2026-09-22-pin-vs-auto
make status                                # is it still going?
make report                                # when it finishes
make publish STUDY=2026-09-22-pin-vs-auto  # promote it into results/ to commit

# --- optional: a second VPS adds upload, iperf3 UDP and sender-CC control ---
sudo ./setup/01-iperf-server.sh --allow-from <VM_PUBLIC_IP>     # on that box
sudo -E ./bench/gvpn-bench.sh -s <IPERF_HOST> --profile soak --detach
```

`--dry-run` on any profile prints the schedule and estimated wall clock before committing.

## Reading the result

```sh
make report                    # newest run, floor 5, writes report.md beside it
# or explicitly:
python3 ./bench/gvpn-analyze.py ~/gvpn-state/runs/<newest> \
        --floor-mbps 5 --markdown ~/gvpn-state/runs/<newest>/report.md
```

The report opens with a verdict in words and four numbers, and only then shows the
tables behind it. The first fifteen lines are the answer; everything after them is
for whoever wants to argue with it.

Three things to know before you quote a number from it:

- **The floor threshold comes from the study file, not the command line.** Set
  `GVPN_FLOOR_MBPS` in `studies/<name>.conf` before the run — take `auto`'s p25
  from the quick run — and the bench records it in the manifest, which is what
  `make report` then uses. `--floor-mbps` still overrides it, and the report
  prints a caveat saying it was overridden. Choosing the threshold after seeing
  the pinned arm turns the headline number into whatever you wanted.
- **The bracketed ranges are 90% bootstrap confidence intervals.** A p10 over a
  few dozen sessions is a single order statistic; it moves. An interval that spans
  zero means the arms are indistinguishable at that sample size, however large the
  percentage in front of it looks. The verdict line says so in words.
- **Check `distinct routes` reads 1.0 for the pinned arm.** If it does not, the
  manual hopr-lib config was never loaded and the run compared `auto` with itself.
  The report refuses to claim a result in that case, but it is worth knowing why.

`--markdown` writes the same thing as a file that can be pasted into #8408
unedited — verdict, per-arm table, per-exit table, the evidence table, and a
collapsed glossary so a reader does not have to ask what `p90/p10` means.
`--no-diagnostics` trims it to the headline and per-exit tables.

## The arms

| Arm | What it changes | What it isolates |
|---|---|---|
| `auto` | nothing — stock production config, 1 hop | control |
| `pin-planner` | `max_cached_paths = 1`, `return_path_exploration = 0` | **one path, forward and return** |
| `no-explore` | `return_path_exploration = 0` only | the 10 % blind return draws, alone |
| `narrow` | 3 candidates, weights untempered | whether a shippable middle ground exists |
| `zero-hop` | `hops = 0` | upper bound — no relay in the path at all |
| `pin-cfg-<relay>` | channel allowlist + channels trimmed to one relay | forward leg pinned by topology, return leg free |
| `pin-cfg-pinned-<relay>` | the same, plus `max_cached_paths = 1` | its partner — the gap between the two **is** the return leg |

The last two are a pair and mean nothing apart: both hold the same one-channel
topology, and they differ only in whether the return draw is collapsed too. Both
also carry the allowlist, so the strategy cannot reopen the closed channels
during the other arm's sessions. They need the node trimmed to one channel,
which is node-global, so they run as their own study — see
**`docs/running-all-arms.md`**, which sequences all six arms across three studies.

The pinning lever is worth stating plainly, because it is cheaper than the issue implies:

> hopr-lib's `protocol.path_planner` is `serde(skip)` and `PathPlannerConfig` derives no serde at
> all, so it cannot be set from a hopr-lib YAML — and `deny_unknown_fields` makes the attempt a hard
> failure rather than a no-op. It is set in code, by gnosis_vpn, and **only when it generates the
> config**: `cfg.protocol.path_planner = edgli::latency_path_planner_config(min_ack_rate)` followed
> by `path_planner.apply(&mut ...)`, which layers overrides from gnosis_vpn's own `config.toml`.
> So the lever is a `[connection.path_planner]` section in `config.toml`, and
> `GNOSISVPN_HOPR_CONFIG_PATH` is exactly backwards — it loads `HoprLibConfig` straight from disk
> and never applies the overrides. **`max_cached_paths = 1` there is a real pin of both legs, with
> no recompile and no channel churn.**

Every arm now runs in **generated** mode and differs only in the keys its `config.toml` sets.
`PathPlannerOptions::apply()` leaves unset fields at the preset, so an arm is a genuine diff from
the running configuration rather than a hand-rebuilt one — which also removes the old asymmetry
where a manual-mode arm silently ignored this node's own `[connection.path_planner]` overrides.

Both config layers are `deny_unknown_fields`, so a typo stops the client rather than being silently
ignored. That is a feature, and `use-arm.sh` now detects it and rolls back — but validate before a
long run, not at 3am in cycle 40.

## Load source: with or without a second machine

```bash
--target url            curl a fixed volume from a public endpoint (default URL:
                        Cloudflare's speed endpoint, which returns exactly N bytes)
--target iperf3 -s HOST an iperf3 server you control
```

`url` mode needs **no second machine**. The per-second series comes from sampling the
output file's byte counter once a second — the same shape `iperf3 --interval 1` produces, so
the analyser reads both identically. Download only by default; `--url-up` adds a POST leg.

**Loss and jitter do not require a second machine either.** Two measurements with no
congestion controller in the loop are captured on every run:

- **`ping.txt`** — a ping runs through the tunnel for the whole session, alongside the
  transfer. Its summary gives loss and `mdev` jitter *under load*. The analyser reports these
  as `ploss%` / `pjit_ms`.
- **Session telemetry** — `hopr_session_frame_discarded_total` (frames that arrived but missed
  the reassembly window), `time_to_finish_frame`, retransmission requests. Reported as `disc%`.
  These are scoped to the HOPR leg rather than the whole internet path, which is what the study
  is actually about.

The iperf3 UDP leg adds a third view but is optional: `--udp-host` can point at a public
iperf3 server even in `url` mode. The one thing that genuinely needs a machine you control is
setting the **sender's** congestion control for downloads (CUBIC vs BBR) — for `iperf3 -R` the
sender is the far end, not this box.

## Profiles

| Profile | Shape | Wall clock (4 arms) | Use for |
|---|---|---|---|
| `smoke` | 1 cycle, 1 rep, 25 MB | ~10 min | is the rig working |
| `quick` | 3 cycles, 1 rep, 25 MB | ~35 min | is there a signal |
| `standard` | 30 cycles, 3 reps, 60 s legs | ~15 h | the matrix |
| `transfers` | 30 cycles, 1 rep, 25 MB each way | **~3 h** (2 arms, 1 exit) | **start here** — fixed volume, like the team's existing test |
| `soak` | 36 h budget, 3 reps, 60 s legs | ~1.5 d | unattended, spans day and night |
| `persistence` | 6 cycles, 5 reps × 25 MB, 5 min gaps | ~12 h | within-session stability |

Every knob overrides the profile: `--profile soak --mode bytes --dl-bytes 25M --duration 48h`
gives a two-day schedule built from 25 MB transfers. A `studies/*.conf` can set the same knobs
(`GVPN_MODE`, `GVPN_CYCLES`, `GVPN_REPS`, `GVPN_DL_BYTES`, `GVPN_UL_BYTES`, `GVPN_ARMS`,
`GVPN_DESTINATIONS`, …), so a study is fully described by its file rather than by the flags
someone happened to type. Flags still beat the study file; the study file beats the profile.

**Wall clock is `~3 min × arms × exits × cycles`** — the transfers are a minority of it. A 25 MB
leg is ~40 s; connecting, settling and cooling down between arms cost more than the data does.
So the 36-hour figure is `5 arms × 3 exits × 30 cycles`, not an inherent cost. Cut arms and exits
freely; think before cutting cycles, which is the only factor that buys statistical power. See
**`docs/running-all-arms.md`** for the ladder from 1 hour to 36.

**Arms are interleaved, never blocked.** Production relay load varies by hour; running arm A for
an hour and arm B for the next hour measures the hour, not the arm. One session per arm per cycle,
round-robin, so every arm sees the same load distribution and `gvpn-analyze.py` can pair them.

## bytes vs time mode

- **bytes** (`iperf3 -n 25M`) — fixed volume, measure the time. Matches the team's existing test
  and is closest to what a user feels. Catch: a floored session takes *longer*, so sessions
  contribute unequal sample counts and the schedule becomes load-dependent. `--leg-timeout` bounds
  it, and timed-out legs are counted in the `to` column rather than quietly dropped — they are the
  worst sessions, so discarding them would flatter the arm.
- **time** (`iperf3 -t 60`) — fixed duration, measure the volume. Equal sample budget per session,
  predictable schedule. This is what a multi-day statistical matrix wants.

## Repeats inside a session, and the TCP question

`--reps N` runs N transfers without reconnecting, `--rep-gap` apart. This is not averaging — it is
a variance decomposition:

- **between-session** variance → what a session *gets*: which relays it holds channels to, its SURB
  warm-up, its exit, how onboarding went.
- **within-session** variance → the per-packet path draw and transient relay load.

That split is the direct answer to "why are *some* sessions bad": does a bad session stay bad for
its whole life, or does it flicker? The analyser prints both, plus a per-repeat row so a session
that decays while held open is visible.

On the congestion-control worry: within one connection CUBIC *does* keep probing upward — the
convex phase past `W_max` exists precisely to escape a stale operating point. What actually pins
throughput is the loss equilibrium, `≈ MSS/RTT × C/√p`: when the session layer discards reordered
frames, TCP reads that as loss and settles wherever `p` and RTT put it, regardless of real capacity.
Three pieces of state are controlled for so the repeats measure the tunnel rather than the
controller's memory:

1. each rep is a new TCP connection, so `cwnd` starts at IW10;
2. `ip tcp_metrics flush` runs between reps, so a bad rep cannot seed the next rep's initial
   `ssthresh` from the kernel's per-destination cache (`--no-flush-metrics` to disable);
3. a `--rep-gap` beyond one RTO trips `tcp_slow_start_after_idle` anyway.

What the gap deliberately does *not* reset is HOPR-side state: the SURB balancer's estimate decays
over minutes and the path cache turns over every 10 s, so a late rep is a fresh draw from a
distribution that has itself moved. That is the interesting part.

## The UDP leg

`--udp-seconds` adds a short `iperf3 -u` download per rep. UDP has no congestion controller, so the
jitter and datagram loss iperf3 reports are the *path's* own. High UDP loss alongside low TCP
throughput is loss-driven CC collapse — which points at the session reassembly window, not at relay
capacity. That distinction decides whether the fix is "buy 8-core relays" or "size the reassembly
window from measured RTT", so it is worth the 10 seconds.

Related: the download's *sender* is the iperf3 host, so **its** congestion control is the one that
matters for downloads. `01-iperf-server.sh` explains how to run one block under CUBIC and one under
BBR. Note the installer already ships `net.ipv4.tcp_congestion_control = bbr` system-wide with the
comment that it "improves throughput and latency of traffic through the tunnel" — the team has
already met this effect empirically.

## Reading the output

```
arm                n fail  to   secs    p10    p50    p90  floor% spread  disc% jit_ms uloss% relays
auto               3    0   0   29.1   5.04   6.45   7.64     0.0    2.0   8.26   45.6   3.19    7.0
pin-planner        3    0   0   37.1   6.17   6.18   6.43     0.0    1.1   0.15    6.5   0.16    1.0
```

The headline is **p10, floor% and spread**, not the mean. An arm that loses a little median
throughput while cutting the floor rate is the outcome this issue asks for — the stated goal is
eliminating random performance floors, not raising the ceiling.

`disc%` is the client's own `hopr_session_frame_discarded_total` over completed frames; `relays` is
how many distinct routes the planner actually drew from, which needs the planner DEBUG logging that
`00-vm-setup.sh` installs. If `pin-planner` does not show `relays = 1`, the manual hopr-lib config
did not take effect — check the drop-in before trusting anything else in the table.

## Safety

A full-tunnel VPN on a remote VM removes your own SSH path. Two independent protections:

1. **Policy route** (`00-vm-setup.sh`) — traffic sourced from the VM's public IP stays off the
   tunnel. Deliberate privacy hole; fine on a throwaway test VM, never on a real one.
2. **Dead-man switch** (`gvpn-bench.sh`, lifted from the team's `vpn-test.sh`) — a detached watchdog
   disconnects when a phase deadline passes, when a hard cap is reached, or when the script dies.

Verify #1 by hand before any long run. Keep the Contabo console reachable as the last resort.

## Known limits

- Relay-side metrics (`hopr_packet_decode_timeouts_total`, `hopr_egress_ring_buffer_dropped`,
  `hopr_mixer_queue_size`) are **not** collected by this kit — they need operator access to the
  relays. Without them the "relays are saturated" and "relays are blocked in the runtime"
  hypotheses cannot be answered, only the path-selection ones. Say so in the report rather than
  guessing.
- `pin-cfg-*` arms need the node's channel set trimmed to one relay, which is node-global: while
  trimmed, this node is not a normal client and `auto` measured on it is not `auto`.
  `tools/close-channels.py` does the trim and `docs/running-all-arms.md` sequences it, but the
  grace period and the strategy's own re-open make it a study of its own, not an arm you can
  interleave.
- One client per host: the client owns the default route and a single identity directory. Multi-
  client aggregation tests need separate network namespaces or separate VMs.
