# #8408 benchmark kit — runbook

Pinned vs. automatic path finding on Gnosis VPN, on a clean Contabo Ubuntu VM.

```
setup/00-vm-setup.sh       prepare the VM under test        (run as root, on the VM)
setup/01-iperf-server.sh   far-end load generator           (run as root, on a 2nd VPS)
setup/02-make-arms.sh      generate the arm configurations  (run as root, on the VM)
setup/03-fetch-sources.sh  clone the pinned sources         (optional — reading code / Phase 4)
setup/04-build-patched.sh  build from source                (optional — Phase 4 only)
setup/05-set-version.sh    switch / pin the client build    (reads gvpn.conf)
setup/06-git-deploy.sh     make the VM a git push target    (run once, on the VM)
                           in-place by default; --bare for a separate repo dir
bench/use-arm.sh           install one arm by hand; --count checks the pin took
bench/gvpn-bench.sh        the interleaved A/B runner
bench/gvpn-analyze.py      per-arm comparison and variance decomposition
docs/plan.md               the full test plan
docs/deploy.md             uploading, fetching source, building
docs/dev-workflow.md       ssh keys, push-to-deploy, switching the client build
gvpn.conf                  every knob in one version-controlled place
```

**`gvpn.conf` is the one file to edit.** Channel, network, pinned version, destination, load
source and log rotation all live there; the setup scripts source it and export it, so the bench
script inherits the same values. Flags still override it.

**The benchmark needs no build.** The client is installed from APT and every pinned arm is pure
configuration. `03` and `04` exist for reading the code while interpreting results, and for the
optional Phase 4 patch. See `docs/deploy.md`.

## What you need before starting

- The Contabo VM (≥ 4 vCPU, ≥ 8 GB RAM, ≥ 40 GB disk — DEBUG logging is hungry).
- Optionally a second VPS for iperf3 — **not required**. `--target url` runs the whole
  comparison from the one VM, loss and jitter included. See "Load source" below.
- Faucet codes, one per allowlist-pinned relay you want to test (`./faucet-codes`, one per line).
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
sudo ./setup/02-make-arms.sh --out ./arms --destination UK
# validate the manual hopr-lib config loads (02-make-arms.sh prints the steps)

# 10-minute rig check -- no second machine needed
sudo ./bench/gvpn-bench.sh --target url --profile smoke --arms-dir ./arms
python3 ./bench/gvpn-analyze.py ./bench-runs/<newest>

# the real run, unattended
sudo ./bench/gvpn-bench.sh --target url --profile soak --arms-dir ./arms --detach

# --- optional: a second VPS adds upload, iperf3 UDP and sender-CC control ---
sudo ./setup/01-iperf-server.sh --allow-from <VM_PUBLIC_IP>     # on that box
sudo ./bench/gvpn-bench.sh -s <IPERF_HOST> --profile soak --arms-dir ./arms --detach
```

`--dry-run` on any profile prints the schedule and estimated wall clock before committing.

## The arms

| Arm | What it changes | What it isolates |
|---|---|---|
| `auto` | nothing — stock production config, 1 hop | control |
| `pin-planner` | `max_cached_paths = 1`, `return_path_exploration = 0` | **one path, forward and return** |
| `no-explore` | `return_path_exploration = 0` only | the 10 % blind return draws, alone |
| `narrow` | 3 candidates, weights untempered | whether a shippable middle ground exists |
| `zero-hop` | `hops = 0` | upper bound — no relay in the path at all |
| `pin-cfg-<relay>` | channel allowlist, one relay | forward leg only (contrast with `pin-planner`) |

The pinning lever is worth stating plainly, because it is cheaper than the issue implies:

> The service honours `GNOSISVPN_HOPR_CONFIG_PATH`. Setting it swaps the worker from a
> *generated* hopr-lib config to one you supply — which exposes the whole `HoprLibConfig`,
> including `protocol.path_planner`. `max_cached_paths = 1` collapses the weighted candidate
> collection to a single validated path, so every packet's forward route and every SURB's
> return route resolve to the same path. **That is a real pin of both legs, with no recompile
> and no channel churn.**

Two gotchas `02-make-arms.sh` handles: manual mode does not inject the safe/module addresses
(they are read from `gnosisvpn-hopr.safe`), and generated mode also tightens probe intervals to
3 s for edge clients (replicated in the YAML, or the node warms up far more slowly).

`HoprLibConfig` is `deny_unknown_fields`, so a typo stops the service rather than being silently
ignored. That is a feature — but validate before a long run, not at 3am in cycle 40.

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
| `soak` | 36 h budget, 3 reps, 60 s legs | ~1.5 d | unattended, spans day and night |
| `persistence` | 6 cycles, 5 reps × 25 MB, 5 min gaps | ~12 h | within-session stability |

Every knob overrides the profile: `--profile soak --mode bytes --dl-bytes 25M --duration 48h`
gives a two-day schedule built from 25 MB transfers.

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
- `pin-cfg-*` arms burn one faucet code each and abandon a funded safe, because the channel
  allowlist only constrains channels while they are being opened.
- One client per host: the client owns the default route and a single identity directory. Multi-
  client aggregation tests need separate network namespaces or separate VMs.
