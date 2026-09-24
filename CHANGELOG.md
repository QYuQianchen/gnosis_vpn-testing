# Changelog

A result is only interpretable against the kit revision that produced it. Every
run's `manifest.json` records `kit_rev`; this file says what changed between
them. Entries are for anything that could move a number — arm settings, the
measurement method, the analysis, the profiles. Not docs or comments.

## Unreleased

### The planner lever is in config.toml, not the hopr yaml

The central mechanism was wrong, and it took a failing run to find it.

`protocol.path_planner` cannot be set from a hopr-lib YAML. The field is
`#[cfg_attr(feature = "serde", serde(skip))]` and `PathPlannerConfig` derives no
serde at all, so it is absent from the schema — and `HoprProtocolConfig` is
`deny_unknown_fields`, so writing the key stops the client rather than being
ignored. It is set in code, by gnosis_vpn, and **only when it generates the
config** (`gnosis_vpn-lib/src/hopr/config.rs`):

    cfg.protocol.path_planner = edgli::latency_path_planner_config(min_ack_rate);
    path_planner.apply(&mut cfg.protocol.path_planner);   // user overrides

Those overrides are `PathPlannerOptions`, read from gnosis_vpn's own
`config.toml` under `[connection.path_planner]` — as the shipped
`networks/jura-dev/config.toml` demonstrates. So `GNOSISVPN_HOPR_CONFIG_PATH`
was exactly backwards: `from_path` deserializes straight from disk and never
applies the overrides, making it the one mode in which the planner cannot be
influenced. The kit reached for the file path *because* it exposed the whole
struct, without checking the planner field was reachable, or that the mode it
was switching away from was the only one doing the work.

- `pin-planner`, `no-explore`, `narrow` and `_pin-cfg-pinned` are now plain
  `[connection.path_planner]` sections in `config.toml`.
- **Every arm runs in generated mode**, which removes a real asymmetry: a
  manual-mode arm ignored this node's own `[connection.path_planner]` overrides,
  so on a node setting `min_paths_anonymity_floor = 3`, `no-explore` was also
  changing the candidate cap from 3 to 50. `apply()` leaves unset fields at the
  preset, so an arm now differs from `auto` in exactly the keys it names — and
  the `planner_preset` / `read_config_planner_overrides` layering that emulated
  this by hand is gone, along with `hopr.yaml`, the `env` file and
  `HOPR_YAML_DEST` (still deleted on install, to clear stale copies).

### use-arm.sh left the node broken on a rejected config

The post-install gate checked `systemctl is-active`, but a rejected hopr config
does not fail the *unit*: the worker starts, reads the file, and parks in Warmup
with the parse error in its status string. The check passed, the script polled
for five minutes, and the node was left wedged. It now asks the client, matches
`config error|unknown field|missing field|Output error`, and **rolls back** —
drop-in removed, previous `config.toml` restored, service restarted and
re-verified.

### Measurement and analysis

- **`--trial` / `--full`.** A rehearsal that keeps the study's arms, exits and
  load source and shrinks only the work (1 cycle, 1 rep, 5 MB). A smaller
  `--profile` would exercise a *different* configuration — how a rehearsal
  passes and the real run fails on its first cycle. The manifest records
  `trial: true` and the analyzer refuses to score such a run, outranking even a
  large measured effect.
- **`--profile transfers`** — 30 cycles, 25 MB each way, one transfer per
  session; ~3 h for two arms against one exit. The gap between `quick` (too few
  sessions for a tail statistic) and `soak` (the full matrix) made the study look
  far more expensive than the question requires.
- **A study file's `GVPN_ARMS` was read by nothing.** Documented and told to
  users, but the bench only accepted `-a`, so a study silently ran *every*
  directory in the arms dir — which after `make arms --pin-relay` would have
  included the `pin-cfg` pair, whose channel trim contaminates every other arm.
  The shape knobs had the same gap; `GVPN_MODE`, `GVPN_CYCLES`, `GVPN_REPS`,
  `GVPN_DL_BYTES` and the rest now fill in between flags and the profile
  (flag > study file > profile).
- **`make dry` ignored the study's profile**, hardcoding `--profile soak`, so
  every study dry-ran as a 36-hour matrix regardless of what it asked for.
- `gvpn-bench.sh` 0.3.0 → 0.4.0: manifest records client service and package
  version, channel, network, `kit_rev` and host congestion control;
  `finished.json` records end time and exit code, so a soak that died at hour 6
  of 48 says so on its own report.
- `gvpn-analyze.py`: verdict-first report; 90 % bootstrap CIs on every
  comparison; a pinned arm still drawing multiple routes voids the report rather
  than footnoting it; `--emit-floor` prints the baseline's p25 for calibration;
  `--markdown` emits an issue-ready document.
- **Arms are a diff from the running config, not a fresh one.** Every planner
  arm used to hardcode the edge-client preset including
  `min_paths_anonymity_floor: 0`, so on a node setting 3 every arm differed from
  the control in two ways at once. Now handled by the client's own `apply()`.

### Operations

- **The kit created the file that blocked its own deploys.**
  `00-vm-setup.sh` wrote `BUILD.txt` into the worktree, and it runs under
  `sudo`, so the file landed root-owned. Being gitignored, `git status` never
  showed it — the first symptom was a push refused for an unwritable worktree,
  with the hook naming a file nobody had touched. It now goes to
  `$GVPN_STATE/BUILD.txt` and the stale copy is removed on setup;
  `05-set-version.sh` reads the new location and falls back to the old one.
  Preflight also warns about a non-deployable worktree, so this surfaces before
  a commit rather than after one.
- **The deploy hook printed a recipe for a problem it had not found** — a canned
  `mv arms` / `mv bench-runs` list regardless of what tripped it, plus a link to
  a doc that no longer exists. It now explains why git cannot proceed and points
  at `tools/fix-worktree-ownership.sh --apply`, which handles every case
  including a single stray file.

- **`bench/preflight.sh`** (`make preflight` / `make launch`) — static checks,
  a route count per arm, the trial, floor calibration, then a detached launch;
  each stage gates the next. Two checks are refusals rather than warnings: a
  `pin-cfg-*` arm in a normal study (its channel trim is node-global), and a
  baseline drawing only one route (a one-channel node has no diversity to lose,
  so every comparison is void). `--pin-current` writes the installed version
  into the study file, so nobody transcribes `2026.09.17+build.134506` by hand.
- **`tools/close-channels.py`** — the channel close, automated end to end
  through blokli. The node key is authorised on the Safe's module, so a close is
  an `execTransactionFromModule` the node signs for itself. Two earlier claims
  are retracted: that retargeting channels needs a new identity, and that it
  cannot be scripted. Losing `eth_call` lost the simulation that proved the
  encoding, so the ABI encoder **self-tests at startup** against independently
  computed vectors (module selector must equal Safe's published `0x468721a7`),
  and the first close is sent **alone as a canary** — the chain is re-read and
  that channel must have moved to `PendingToClose` before any others go. Caught
  a real fault in testing, where a deliberately ineffective transaction reported
  "confirmed".
- **`pin-cfg-*` no longer re-onboards.** Channel closure is an ordinary on-chain
  operation; nothing about retargeting channels needs a new identity. What is
  true is narrower: edgli's strategy only opens and tops up, never closes.
- **`_pin-cfg-pinned`** — `pin-cfg-*` had no partner, so it answered nothing:
  contrasting it with `pin-planner` differs in trimmed-vs-full node as well as
  the leg. `--pin-relay` now renders a pair, identical but for the return draw.
  The partner carries the allowlist too, or the strategy would reopen the closed
  channels during the other arm's sessions.
- **Faucet codes are no longer burned by a failed request.** A code was retired
  *before* checking the faucet's answer, so a timeout permanently spent one that
  never funded anything.
- **`.onboarded` markers survive a re-render**, which previously destroyed a
  funded identity on the next run.
- **State moved out of the worktree** (`$GVPN_STATE`, default `~/gvpn-state`);
  deploys blocked during a run via `run.lock`; the push hook refuses a worktree
  it cannot fully write (checked by absolute path — `push-to-checkout` runs with
  cwd set to `.git`, so scanning `.` silently always passed).
- **`tools/backup-identity.sh`** — replaces a runbook `gpg -c` line that could
  not work: with `tar` on stdin on a headless box, gpg-agent has no terminal and
  dies with `Inappropriate ioctl for device`.
- **`tests/`** — `make test` runs the analyzer and scanner suites. Regressions
  pinned there include: a real address beginning `0xdead` was exempt (benign-list
  applied per line rather than per match); only the first file of a commit was
  scanned (nested read loops shared stdin); a five-cycle run must decline to
  claim a result (scenario `thin`, where one arm's point estimate comes out
  sign-flipped); and a trial run must refuse to score even a large effect.

## Before this

Kit built for hoprnet#8408. `docs/design.md` has the experiment design and the
three corrections it makes to the issue's premise.
