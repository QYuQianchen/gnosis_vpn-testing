# Issue #8408 — pinned vs. automatic path finding: executable test plan

**Owner** Qianchen · **Drafted** 2026-09-11 · **Revised** 2026-09-11 (pinning lever reattributed — see §1.3)
**Target** production (`jura-prod`) · **Host** dedicated Contabo Ubuntu VM
**Code refs** `gnosis_vpn-client@7694d23` (main), `edge-client@d3da1f6`, `hoprnet@87f0e07`
**Kit** `setup/00-vm-setup.sh`, `setup/01-iperf-server.sh`, `setup/02-make-arms.sh`,
`bench/gvpn-bench.sh`, `bench/gvpn-analyze.py`, `README.md`

---

## 1. High-level summary

The issue asks for a bandwidth comparison between automatic path finding and pinned paths. Reading
the code changes what that sentence means, in three ways the plan has to absorb.

**1.1 There is no per-packet "path" today — there is a *distribution* over paths.**
The entry node re-draws the forward route on *every outgoing packet* and the return route on *every
SURB*, as a weighted random draw over up to 50 validated candidates, with 10 % of return draws made
uniformly at random on purpose. A HOPR session is multipath-striped by construction, over legs whose
per-hop mixer delay is `U(0, 20) ms` and whose end-to-end RTTs differ by hundreds of milliseconds.
This is the largest difference between the two arms, and it is a *variance* mechanism, not a
throughput mechanism — which is exactly the symptom being chased ("random performance floors", not
"low ceiling").

**1.2 The config keys named in the issue do not pin a path.**
`min_channel` / `max_channel` / relay allowlist map onto `strategy.min_open_channels`,
`strategy.target_open_channels` and `strategy.channel_allowlist`. Those govern which *payment
channels the entry opens*, i.e. which relays exist as graph edges. That constrains the **forward**
leg only, indirectly, and has to be set *before onboarding* — narrowing the allowlist afterwards
means closing open channels and waiting out the closure period. `path = { intermediates = [...] }`
was removed at config v4→v5 and is explicitly rejected by the v6 parser (`config/v6.rs:983`).

**1.3 But there is a cheaper lever than either, and it needs no recompile.**
The service honours `GNOSISVPN_HOPR_CONFIG_PATH` (`gnosis_vpn-lib/src/hopr/mod.rs:18`). Setting it
switches the worker from a *generated* hopr-lib config to a file you supply — which exposes the
whole `HoprLibConfig`, including `protocol.path_planner`. That is where the draw lives:

```yaml
protocol:
  path_planner:
    max_cached_paths: 1          # collapse the candidate collection to one path
    return_path_exploration: 0.0 # stop the uniform-random return draws
    min_paths_anonymity_floor: 0
    return_path_weight_temper: 1.0
```

`max_cached_paths = 1` leaves the `WeightedCollection` with a single entry, so **every packet's
forward route and every SURB's return route resolve to the same path**. That is a genuine pin of
both legs, per session rather than per identity: no channel churn, no fresh safe, no faucet code
per arm — and no patch. Re-exposing `RoutingOptions::IntermediatePath` in `hopr-lib` (the original
plan) becomes an optional refinement for *choosing which* relay to pin to, not the way in.

Two caveats the arm generator handles: manual mode does not inject the safe/module addresses (read
from `gnosisvpn-hopr.safe`), and generated mode also tightens probe intervals to 3 s for edge
clients, which the YAML must replicate. `HoprLibConfig` is `deny_unknown_fields`, so a typo stops
the service rather than being silently ignored — validate before a long run.

**The shape of the experiment.** Six arms against one control, **interleaved in time**, on one VM,
with repeats inside each session. The primary metric is not mean throughput; it is the **shape of
the lower tail** — p10 of session throughput, the fraction of sessions below a floor threshold, and
p90/p10 spread — because raising the floor is the stated goal. The design is built so the competing
hypotheses produce **different, pre-registered signatures** and can be told apart from one run
rather than argued about afterwards.

---

## 2. Step-by-step analysis

### 2.1 How a route is actually chosen

`PathPlanner::resolve_routing` is called per packet:

```
transport/hopr/src/path/planner.rs
  resolve_routing()            → per outgoing packet
    resolve_path(me → dest)    → weighted draw from cached WeightedCollection
    resolve_diverse_return_paths(dest → me, count)
                               → per SURB: 90 % weighted draw (weights^0.5), 10 % uniform
```

Candidates are rebuilt from the channel graph and cached under `(src, dest, hops)` with
`cache_ttl = 10 s`, refreshed every `5 s`. Weight per candidate is

```
composite_weight = cost × latency_factor(total_latency, halflife) × capacity_factor(tickets, ref)
latency_factor(l, h) = 1 / (1 + l/h)
```

The edge client overrides the hoprd defaults (`edge-client/src/lib.rs:59`):

| Knob | hoprd default | edge client | Effect |
|---|---|---|---|
| `latency_halflife` | 100 ms | 100 ms (explicit) | latency is a *soft* weight — a 100 ms path keeps half the weight of a 0 ms one |
| `min_paths_anonymity_floor` | 8 | **0** | latency pruning **disabled**; every ack-passing relay retained, up to `max_cached_paths = 50` |
| `return_path_weight_temper` | 0.5 | 0.5 | weights flattened, deliberately spreading SURBs wider |
| `return_path_exploration` | 0.1 | 0.1 | 10 % of return draws ignore quality entirely |

Read together: **the edge client is tuned to maximise relay diversity, not throughput.** Each of
those choices has a documented reliability or anonymity rationale, and each widens the latency
spread a single session's packets experience.

### 2.2 Why diversity plausibly *is* the performance floor

Downstream sits the session reassembly layer. From the 2026-09-08 return-path-stall analysis in
this project, the WireGuard tunnel session runs with `max_frames_behind_gap = 256` and
`max_frame_age = 2 s`. At the measured 107 frames/s that window is 2.4 s; at 1,300 frames/s it is
0.2 s. A frame arriving outside it is discarded although it arrived intact — 13,354 frames
discarded in a 45-minute run, 60 % of "already seen" rejections beyond the window.

Multipath striping is a *reordering source*; the reassembly window is a *reordering budget*:

```
per-packet jitter ≈ mixer delay (2 hops × U(0,20) ms)
                  + spread of end-to-end RTT across the N relays currently in the draw
```

If relay A returns in 120 ms and relay B in 600 ms and both are drawn, arrivals interleave with a
~480 ms spread — on top of the 10 % of return draws that deliberately land on unmeasured relays.
When the spread exceeds the window, the session layer discards, WireGuard sees loss, and the TCP
flow inside the tunnel collapses to a floor. **Pinning collapses the spread to one path's jitter.**

This is a hypothesis, not a finding. §3 states what it predicts.

### 2.3 Why the floor is a loss equilibrium, not CUBIC's memory

A natural worry is that TCP finds a low operating point and stays there. Within one connection
CUBIC does keep probing upward — the convex phase past `W_max` exists precisely to escape a stale
point. What actually pins throughput is the loss equilibrium: for a loss-based controller,

```
throughput ≈ MSS/RTT × C/√p
```

Discarded reordered frames look to TCP exactly like random loss `p`, so the window settles wherever
`p` and RTT put it, regardless of available capacity. A path with 1 % non-congestive loss and
300 ms RTT caps in single-digit Mbit/s however much capacity is behind it.

Three corollaries the experiment acts on:

1. **Measure the path without a controller in it.** A short `iperf3 -u` leg per repeat reports
   jitter and datagram loss directly. High UDP loss with low TCP throughput ⇒ loss-driven CC
   collapse ⇒ the fix is the reassembly window, not bigger relays.
2. **Control the kernel's cross-connection memory.** Linux caches per-destination metrics and seeds
   `ssthresh` from them, so a bad transfer can pessimise later ones; `ip tcp_metrics flush` between
   repeats removes that. (A repeat gap beyond one RTO also trips `tcp_slow_start_after_idle`.)
3. **The download's sender is the far end.** For `iperf3 -R` the CC that matters is the iperf3
   host's, not the VM's. Worth one deliberate CUBIC-vs-BBR block. Note the installer already ships
   `net.ipv4.tcp_congestion_control = bbr` system-wide, commented as improving tunnel throughput —
   the team has met this effect empirically already.

### 2.4 What the pinning levers actually give you

| Lever | Forward leg | Return leg | Recompile | Cost per arm switch |
|---|---|---|---|---|
| `path_planner.max_cached_paths = 1` via `GNOSISVPN_HOPR_CONFIG_PATH` | **yes** | **yes** | no | service restart |
| `strategy.channel_allowlist` + `min/target_open_channels = 1` | yes | no | no | fresh identity + faucet code + onboarding |
| `path = { hops = 0 }` (+ `--allow-insecure`) | n/a — no relay | n/a | no | service restart |
| patched `RoutingOptions::IntermediatePath` | yes, **chosen** | yes, chosen | yes | service restart |

Row 1 is the workhorse. Row 2 is kept because comparing it against row 1 **isolates the return-leg
striping on its own** — the cleanest single measurement in the plan. Row 3 is the upper bound.
Row 4 only matters once you want to pin to a *named* relay rather than to whichever candidate the
planner ranks first; that is what turns `pin-busy` vs `pin-idle` into a controlled comparison.

### 2.5 Open question to settle in Phase 0

Return-path candidates come from `compute_paths(graph, src = exit, dest = me, …)` over the channel
graph, whose edges are open channels. A pinned return path `exit → R → me` therefore appears to
need a channel `R → me`, which relay operators do not open toward arbitrary clients. The forward
phase-2 comment (`selector.rs:472` — *"assume the last hop can be done by anybody"*) and the fact
that return paths work today both suggest the final delivery hop is exempt. Confirm empirically:
if `pin-planner` resolves return paths without `PathNotFound`, it is exempt.

### 2.6 What the existing harnesses give us

- **`gnosis_vpn-system_tests`** (`src/download.rs`) already spawns the service, waits for
  destination readiness, connects, and does sized downloads with repetitions into a report table.
  Its statistic is `avg / min / max` of whole-file wall time — good bones, wrong statistic for a
  floor study.
- **the teammate's `vpntest.sh`** contributes the three genuinely hard parts: the **dead-man
  switch** (mandatory — a full-tunnel VPN on a remote VM removes your own SSH path), the
  **fresh-identity + faucet onboarding loop**, and stable `ctl -o plain` parsing. Its gaps for this
  task: ping-only, no config swapping between arms, no telemetry capture, and — most important on
  production — arms as **sequential blocks**, which confounds the arm with time-of-day load.
  `bench/gvpn-bench.sh` reuses its primitives and closes those four gaps.
- **`gnosis_vpn-ctl telemetry`** dumps the embedded entry node's full Prometheus text (the
  `telemetry` feature is on in the shipped build) — the client-side instrumentation channel, no
  recompile.

---

## 3. Hypotheses, pre-registered

Writing these down *before* the run is what stops the analysis becoming a story fitted to the data.

| # | Hypothesis | Signature if true | Signature if false |
|---|---|---|---|
| **H1** | Relays saturated by aggregate traffic | relay `hopr_packets_count{type=forwarded}` plateaus; `hopr_egress_ring_buffer_dropped` climbs; `hopr_mixer_queue_size` grows; floors correlate with *which* relay | pinned-idle ≈ pinned-busy; relay counters far from any ceiling |
| **H2** | Relays blocked in the runtime, not on CPU | `hopr_packet_decode_timeouts_total` rises while relay CPU stays well under 100 % (that metric's own description names Rayon-pool saturation) | decode timeouts stay at zero throughout |
| **H3** | Multipath striping + a LAN-sized reassembly window is the floor mechanism | `auto` shows high `hopr_session_frame_discarded_total` and wide p10↔p90; pinned arms show near-zero discards and a much **tighter** distribution even where the median is no better; floor incidence tracks distinct-relay count | discards comparable across arms; the distribution does not tighten under pinning |
| **H4** | Client aggregation onto shared relays causes the floors | N clients on the **same** relay degrade sharply vs. N on **distinct** relays at equal offered load | the two multi-client arms are indistinguishable |
| **H5** | Loss-driven CC collapse, not missing capacity | UDP leg shows multi-percent datagram loss while TCP sits far below the UDP rate; a BBR sender beats a CUBIC sender over the same arm | UDP loss ≈ 0 and TCP ≈ UDP throughput; CC makes little difference |
| **H6** | Automatic path finding is *not* implicated | pinned and auto distributions coincide within noise across all arms | — |

Not mutually exclusive. They are separated because they imply different fixes: H1 → more/bigger
relays (the proposed short-term mitigation); H2 → a runtime fix, and bigger machines would be wasted
money; H3/H5 → size the reassembly window from measured RTT and reduce deliberate diversity under
load; H4 → spread clients across relays.

---

## 4. Experiment design

### 4.1 Arms

| Arm | Change from control | Discriminates |
|---|---|---|
| `auto` | none — stock prod config, 1 hop | control |
| `pin-planner` | `max_cached_paths = 1`, `exploration = 0` | **H3** — one path, both legs |
| `no-explore` | `exploration = 0` only | the 10 % blind return draws alone |
| `narrow` | 3 candidates, `temper = 1.0`, no exploration | whether a shippable middle ground exists |
| `pin-cfg-<relay>` | channel allowlist, one relay | forward leg only — vs `pin-planner` isolates the **return** leg |
| `zero-hop` | `hops = 0` | upper bound; isolates entry/exit/session from the relay |
| `pin-busy` / `pin-idle` | pinned to a high-load vs low-load relay | **H1, H2** |
| `multi-same` / `multi-diff` | 4 clients, shared vs distinct relays | **H4** |

`pin-cfg` exists because if it and `pin-planner` diverge, the difference **is** the return-leg
striping. A single pinned arm cannot separate "pinning helps" from "this relay happens to be good" —
hence `pin-busy`/`pin-idle` and relay rotation.

### 4.2 Interleaving — non-negotiable on production

Relay load varies by hour. Arms are cycled **round-robin**, one session per arm per cycle, so every
arm sees the same load distribution and the analyser can report **paired per-cycle deltas** rather
than pooled means.

```
cycle k:  auto → pin-planner → no-explore → narrow → zero-hop → (repeat)
```

### 4.3 Profiles and schedule

| Profile | Shape | Wall clock (4 arms) | Purpose |
|---|---|---|---|
| `smoke` | 1 cycle, 1 rep, 25 MB | ~10 min | rig check |
| `quick` | 3 cycles, 1 rep, 25 MB | ~35 min | signal check |
| `standard` | 30 cycles, 3 reps, 60 s legs | ~15 h | the matrix |
| `soak` | 36 h budget, 3 reps, 60 s legs | ~1.5 d | unattended, spans day and night |
| `persistence` | 6 cycles, 5 reps × 25 MB, 5 min gaps | ~12 h | within-session stability |

`--dry-run` prints the schedule and estimate before committing. Every knob overrides the profile,
so `--profile soak --mode bytes --dl-bytes 25M --duration 48h` gives a two-day schedule built from
the team's existing 25 MB transfer size.

**bytes vs time.** `--mode bytes` (`iperf3 -n 25M`) is comparable with existing team numbers and
closest to user experience, but a floored session takes longer, so sessions contribute unequal
sample counts and the schedule becomes load-dependent; `--leg-timeout` bounds it and timed-out legs
are **counted, not dropped** — they are the worst sessions, so dropping them would flatter the arm.
`--mode time` gives every session the same sample budget and a predictable schedule, which is what
the multi-day matrix needs.

### 4.4 Sample size

The quantity of interest is a lower-tail quantile, which needs more samples than a mean.
**≥ 30 sessions per arm** gives a usable p10 across sessions and ~1,800 one-second samples per arm.
Relay identity is rotated across cycles for the pinned arms (≥ 3 relays × ≥ 10 sessions) so an arm
is not confounded with one relay's idiosyncrasies.

### 4.5 Repeats inside a session — the variance decomposition

`--reps N` runs N transfers without reconnecting, `--rep-gap` apart. This is not averaging; it
splits the variance:

- **between-session** → what a session *gets*: which relays it holds channels to, SURB warm-up,
  exit, how onboarding went.
- **within-session** → the per-packet path draw and transient relay load.

That split is the direct answer to "why are *some* sessions bad": does a bad session stay bad for
its whole life, or does it flicker? Nothing else in the plan answers it. TCP state is controlled per
§2.3 so the repeats measure the tunnel, not the controller's memory. The `persistence` profile
(5 × 25 MB with 5-minute gaps) is the explicit test of a held-open session, and its gaps are long
enough for the SURB balancer's estimate to decay — so a late repeat is a fresh draw from a
distribution that has itself moved.

### 4.6 Load generator

`iperf3` against a VPS we control in a different AS — not a public speed test: we need a stable far
end, 1-second interval reporting, both directions, and the ability to set the *sender's* congestion
control for downloads. Download (`-R`) is the SURB-hungry direction and gets the longer leg. A short
UDP leg per repeat gives jitter and datagram loss with no CC in the path (§2.3). `ping -i 0.25` runs
in parallel for an RTT and loss time series on the same clock.

### 4.7 Metric definitions — fix these before looking at any data

- **Session throughput** = median of the 1-second iperf3 samples, first 5 s dropped; for a
  multi-rep session, the median across its repeats.
- **Floor rate** = fraction of sessions whose throughput < 2 Mbit/s. *(Placeholder — set from the
  `auto` arm's observed p25 in Phase 1, then freeze.)*
- **Within-session stall rate** = fraction of 1-second samples below 10 % of that session's median.
- **Tail spread** = p90 / p10 of the 1-second samples, per session.
- **Between/within CV** = coefficient of variation across session medians, and across repeats
  within a session.

The headline comparison is **floor rate, p10 and tail spread**, not mean throughput. A pinned arm
5 % slower on average with a quarter of the floor rate is a win under this issue's own reasoning.

---

## 5. Instrumentation

Three planes on one wall clock (hence chrony in the VM setup — an unsynced clock silently destroys
the join).

**Client (VM under test)**
- `gnosis_vpn-ctl -o json nerd-stats` every 2 s → SURB estimates, WG counters, session ids.
- `gnosis_vpn-ctl telemetry` every 5 s → full Prometheus text:
  `hopr_session_frame_discarded_total`, `…frame_completed_total`, `…time_to_finish_frame`,
  `hopr_session_ack_*_retransmission_requests_total`, `hopr_session_surb_*`,
  `hopr_surb_balancer_*`, `hopr_path_length`.
- Service log with path attribution:
  `RUST_LOG=info,hopr_transport::path::planner=debug,hopr_transport::path::selector=debug`
  → `weighted candidate path` (with `path`, `composite_weight`, `sampling_probability`,
  `total_latency_ms`) and `[forward]/[return] candidate path`. **This is how distinct relays drawn
  per session are counted** — the core H3 measurement, and the check that a pin actually took.
- `iperf3 --json --interval 1` (TCP both directions + UDP), `ping -i 0.25`, `sysstat` per-core CPU.

**Relay / exit (needs ops access — H1 and H2 stand or fall on this)**
- `hopr_packets_count{type}`, `hopr_egress_ring_buffer_dropped`, `hopr_mixer_queue_size`,
  `hopr_mixer_average_packet_delay`, `hopr_packet_decode_timeouts_total`,
  `hopr_packet_rejected_count{reason}`, `hopr_channels_count`.
- Per-core host CPU (so a saturated Rayon pool is visible against low aggregate CPU), RAM, NIC
  bytes/packets/drops. Sampled ≤ 15 s, for the same window on neighbouring relays too.

> **Dependency.** H1 and H2 cannot be answered from the client alone. If relay metrics are not
> scrapeable when the run starts, Phases 1–4 still complete and answer H3/H4/H5/H6; H1/H2 are
> deferred and the report says so explicitly rather than speculating.

**Safety**
- Dead-man switch, unconditionally, plus the source-based policy route that keeps SSH off the
  tunnel. Verify the policy route by hand *before* any long run; keep the Contabo console as the
  last resort.

---

## 6. Phases

### Phase 0 — bring-up and feasibility (0.5–1 day)

1. `setup/00-vm-setup.sh --network jura-prod --allow-insecure` on the VM;
   `setup/01-iperf-server.sh --allow-from <VM_IP>` on the second VPS.
2. Onboard one identity, reach `Ready`, confirm a clean `iperf3 -R` end to end.
3. **Verify SSH survives a connect.** Then test that the dead-man switch recovers from a hang.
4. `setup/02-make-arms.sh --destination USA`, then validate the manual hopr-lib config loads —
   `deny_unknown_fields` means a typo stops the service, and that must be discovered now.
5. Confirm the pin took: `pin-planner` shows **one** distinct path in the planner DEBUG lines,
   `auto` shows many. If both show many, the drop-in did not take effect.
6. **Record the baseline**: how many distinct relays does one 60 s `auto` session actually draw
   from, and what is their latency spread? That number is worth reporting even if nothing else lands.
7. Settle §2.5 (does a pinned return path resolve?).
8. `--profile smoke`, then `--profile quick`.

*Exit criteria:* one clean session measured end to end, path attribution working, the pin verified,
relay shortlist in hand, return-pinning feasibility known.

### Phase 1 — signal check (0.5 day)

`--profile quick` across `auto`, `pin-planner`, `no-explore`, `narrow`, `zero-hop`. Not a result —
a check that the arms differ at all and that the analysis pipeline produces the table. Set the floor
threshold from `auto`'s p25 here, then freeze it.

### Phase 2 — the matrix (1.5–2 days wall clock, unattended)

`--profile soak --detach`, ≥ 30 sessions per arm, 3 repeats each, relay rotation.
Add `pin-cfg-<relay>` arms once faucet codes are in place — this is where the return-leg isolation
comes from.

*Deliverable:* the comparison the acceptance criteria asks for — distributions, floor rate, tail
spread, discard counters, UDP jitter/loss, distinct-relay counts, per arm and per relay.

### Phase 3 — persistence and congestion control (0.5–1 day)

`--profile persistence` for the held-open-session question. Then one `standard` block with the
iperf3 host on CUBIC and one on BBR, to resolve H5.

### Phase 4 — the patch, only if Phase 2 justifies it (1–2 days)

Needed only to pin to a *named* relay, which is what makes `pin-busy` vs `pin-idle` controlled.
Three edits on a branch, never merged to a release line:

1. `hoprnet`, `hopr/hopr-lib/src/lib.rs` — `HopRouting` becomes an enum behind an `explicit-path`
   feature, with `From<HopRouting> for RoutingOptions` mapping the new variant to
   `RoutingOptions::IntermediatePath` (the planner already honours it, `planner.rs:614`). Keep
   `hop_count()` working for both variants — `route_health.rs` and `Destination::pretty_print_path`
   call it.
2. `gnosis_vpn-client`, `gnosis_vpn-lib/src/config/v6.rs` — re-accept
   `path = { intermediates = [...] }`; the v4 parser already had it, restore that arm.
3. `gnosis_vpn-client/Cargo.toml` — `[patch]` both `edgli` and `hopr-utils-session` to local
   checkouts. **Read the comment already in that file**: `?branch=X#sha` and `?rev=sha` are distinct
   sources to Cargo, and mixing them builds hoprnet twice and fails with a confusing type mismatch.

### Phase 5 — multi-client aggregation (1–2 days)

`multi-same` vs `multi-diff`, N = 4. **One client per network namespace or per VM** — the client
owns the default route and a single identity directory. Stagger starts by 30 s.

### Phase 6 — relay-side correlation and report (1 day)

Join relay metrics to client sessions on the wall clock. Answer H1 and H2 explicitly: does forwarded
packet rate plateau, do egress drops appear, do decode timeouts appear at low CPU.

*Deliverable:* the issue's two acceptance criteria. The recommendation must say **which** fix the
data supports: bigger relays (H1), a runtime fix (H2), reassembly-window and diversity tuning
(H3/H5), client spreading (H4), or "path finding is not the problem" (H6).

---

## 7. Risks and handling

| Risk | Handling |
|---|---|
| Losing SSH when the tunnel comes up | Source-based policy route + dead-man switch + Contabo console. Both verified by hand in Phase 0. |
| Production load drifts and swamps the arm effect | Round-robin interleaving; ≥ 30 sessions/arm; paired per-cycle deltas reported, not just pooled means. |
| A manual hopr-lib config stops the service mid-run | `deny_unknown_fields` fails loudly; the runner captures `journalctl` on a failed restart and continues to the next arm rather than stalling. Validate in Phase 0. |
| Arm state leaking between arms | The runner rewrites *and removes* the config, the hopr YAML and the drop-in on every arm switch. A planner-pinned config left in place would silently invalidate the whole comparison. |
| Channel churn cost for `pin-cfg` | Allowlist set before onboarding; one identity reused for all sessions of one relay; faucet ledger reused from `vpntest.sh`. |
| Relay metrics not ready | Phases 1–5 proceed; H1/H2 explicitly deferred in the report. |
| DEBUG planner logging too voluminous | Only the two planner targets; size-based rotation at 200 MB (the 2026-09-08 run hit the packaged 100 MB rotation and lost the interesting lines). |
| 0-hop exposes the client IP to the exit | Measurement baseline only, throwaway identity, flagged as never a product configuration. |

---

## 8. Acceptance criteria — mapping

| Issue requirement | Where satisfied |
|---|---|
| Execute benchmark sessions comparing automatic vs pinned-path routing | Phases 1–3 |
| Measure and document bandwidth results from both approaches | Phase 2 deliverable, §4.7 metric definitions |
| Analyse findings to identify performance gaps and improvement opportunities | Phase 6, H1–H6 resolution |
| Document bandwidth comparison results between both routing modes | Phase 6 report |
| Provide conclusions explaining performance differences and recommended improvements | Phase 6 — must name the supported fix, not list all of them |

Action items from the meeting notes map as: static route testing → Phases 1–3; comparative analysis
→ Phases 2 and 6; relayer capacity monitoring → Phase 6 (dependent on monitoring infrastructure).
