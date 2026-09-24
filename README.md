# #8408 benchmark kit

Pinned vs. automatic path finding on Gnosis VPN, on a dedicated Ubuntu VM.

```sh
make push                                    # Mac
ssh gvpn-vm && cd ~/gvpn-8408

sudo ./setup/00-vm-setup.sh --network jura-prod --allow-insecure
gnosis_vpn-ctl start-client 60m              # ONBOARD -- wait for Ready
sudo -E ./setup/02-make-arms.sh              # needs the identity from above

sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --pin-current --trial-only
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --launch -y
```

- **`docs/run.md`** — every field to configure, and the commands. Start here.
- **`docs/studies.md`** — how long it takes and why, and the three studies.
- **`docs/design.md`** — why the experiment is shaped this way; the corrections
  it makes to the issue's premise.

## Layout

Two trees, and the split is the whole design: **the repo holds what re-creates
an experiment; the state directory holds what an experiment produces or what
identifies this node.** A deploy rewrites the worktree, so nothing irreplaceable
lives there.

```
gvpn-8408/                    the repo — safe to force-checkout at any moment
  gvpn.conf                   machine defaults: channel, network, load source
  studies/<date>-<name>.conf  one tracked file per experiment, named in its report
  arms/<name>/                arm TEMPLATES — prose, hop count, config fragment.
                              No addresses, so they are tracked and diffable.
  lib/common.sh               kit root, state dir, config loading
  setup/00-vm-setup.sh        prepare the VM                        [VM, root]
       02-make-arms.sh        render templates into the state dir   [VM, root]
       05-set-version.sh      switch / pin the client build
       06-git-deploy.sh       make the VM a git push target         [once]
       01,03,04               iperf server, source fetch, patched build (Phase 4)
  bench/preflight.sh          checks → trial → calibrate → launch
        gvpn-bench.sh         the interleaved A/B runner
        gvpn-analyze.py       the report
        use-arm.sh            install one arm by hand; --count checks the pin took
  tools/close-channels.py     trim channels via the Safe, through blokli
        scan-secrets.sh       refuses addresses and peer IDs in a commit
        diagnose.sh install-hooks.sh backup-identity.sh fix-worktree-ownership.sh
  tests/                      make test — analyzer and scanner suites
  results/<study>/            COMMITTED: report.md, summary.csv, manifest.json
```

```
~/gvpn-state/                 never tracked, never inside the worktree
  runs/                       raw output — GBs of planner DEBUG logging
  arms/<name>/                RENDERED arms, carrying this node's addresses
  secrets/  identity-backup/
  run.lock -> runs/<id>       exists during a run; blocks deploys
```

Three consequences:

- **`arms/` in the repo is not runnable.** `make arms` renders templates into
  `~/gvpn-state/arms`, which is what the bench reads. Editing a planner setting
  is a commit — a silent change invalidates every comparison after it.
- **A push is rejected while a run is in progress.** Wait, or clear a stale
  `~/gvpn-state/run.lock`.
- **Run `make hooks` once per clone.** Git does not sync hooks, and the
  realistic way an address reaches the repo is a log excerpt pasted into a doc.

## The arms

| Arm | What it changes | What it isolates |
|---|---|---|
| `auto` | nothing — stock config, 1 hop | control |
| `pin-planner` | `max_cached_paths = 1`, `return_path_exploration = 0` | **one path, forward and return** |
| `no-explore` | `return_path_exploration = 0` only | the blind return draws, alone |
| `narrow` | 3 candidates, weights untempered | whether a shippable middle ground exists |
| `zero-hop` | `hops = 0` | upper bound — no relay at all |
| `pin-cfg-<relay>` | allowlist + channels trimmed to one relay | forward leg pinned by topology |
| `pin-cfg-pinned-<relay>` | the same, plus `max_cached_paths = 1` | its partner — the gap **is** the return leg |

The last two are a pair and mean nothing apart. They need the node trimmed to
one channel, which is node-global, so they run as their own study.

Every arm is a `[connection.path_planner]` diff in gnosis_vpn's `config.toml`,
applied in **generated** mode — `PathPlannerOptions::apply()` leaves unset
fields at the preset, so an arm differs from `auto` in exactly the keys it
names. `docs/design.md` §3 explains why the hopr-lib YAML is the wrong place.
Both config layers are `deny_unknown_fields`, so a typo stops the client;
`use-arm.sh` detects that and rolls back.

## Profiles

| Profile | Shape | Wall clock | Use for |
|---|---|---|---|
| `smoke` | 1 cycle, 1 rep, 25 MB | ~10 min | is the rig working |
| `quick` | 3 cycles, 1 rep, 25 MB | ~35 min | is there a signal |
| `transfers` | 30 cycles, 1 rep, 25 MB each way | **~3 h** (2 arms, 1 exit) | **start here** |
| `standard` | 30 cycles, 3 reps, 60 s legs | ~15 h | the matrix |
| `soak` | 36 h budget, 3 reps, 60 s legs | ~1.5 d | unattended, spans day and night |
| `persistence` | 6 cycles, 5 reps × 25 MB, 5 min gaps | ~12 h | within-session stability |

`--trial` shrinks any study to 1 cycle × 5 MB for a rehearsal. Flags beat the
study file; the study file beats the profile. `make dry STUDY=…` prints the
schedule and wall clock before committing to it.

**Arms are interleaved, never blocked.** Relay load varies by hour; running arm
A for an hour and B for the next measures the hour, not the arm. One session per
arm per cycle, round-robin, so the analyser can pair them.

## Reading the result

`make report` opens with a verdict in words and four numbers; the tables behind
it follow. Three things before quoting anything:

- **The floor threshold comes from the study file**, recorded in the manifest.
  `--floor-mbps` still overrides it and the report says so.
- **Bracketed ranges are 90 % bootstrap CIs.** An interval spanning zero means
  the arms are indistinguishable at that sample size, however large the
  percentage in front of it.
- **`distinct routes` must read 1.0 for the pinned arm.** If not, the run
  compared `auto` with itself; the report refuses to claim a result.

`--markdown` writes the same thing as a file that pastes into #8408 unedited.

## Safety

A full-tunnel VPN on a remote VM removes your own SSH path. Two protections:
the **policy route** (`00-vm-setup.sh`) keeps traffic sourced from the VM's
public IP off the tunnel — a deliberate privacy hole, fine on a throwaway test
VM and never on a real one; and a **dead-man switch** in `gvpn-bench.sh` that
disconnects on a phase deadline, a hard cap, or the script dying. Verify the
first by hand before any long run and keep the console reachable.

## Known limits

- Relay-side metrics need operator access to the relays; without them the
  "relays are saturated" and "blocked in the runtime" hypotheses cannot be
  answered, only the path-selection ones.
- `pin-cfg-*` needs the channel set trimmed, which is node-global: while
  trimmed, this node is not a normal client.
- One client per host — the client owns the default route and a single identity.
  Multi-client aggregation tests need separate namespaces or VMs.
