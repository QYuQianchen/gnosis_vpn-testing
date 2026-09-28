# Changelog

A result is only interpretable against the kit revision that produced it; every
run's `manifest.json` records `kit_rev`. Entries here are for changes that can
move a number or break a node — not for docs or comments.

## Unreleased

### Fixed — the trial aborted before its first session

- **`gvpn-bench.sh: line 862: CODES_LEDGER: unbound variable`.** Removing
  faucet codes deleted the variables but left two `touch` lines that used them;
  under `set -u` the bench stopped before connecting anything. The bench had only
  ever been syntax-checked.
- **A trial could never produce a readable report.** The analyzer drops the first
  5 s of every transfer (TCP slow start). A 5 MB trial at 20 Mbit/s is over in
  2 s, so nothing was left and every trial read "no usable sessions". Worse, a
  fast 25 MB session in a real study would have been dropped the same way —
  discarding exactly the fastest sessions. A transfer too short for the window is
  now scored by its whole-transfer rate (no tail or stall figures), and the report
  counts such transfers in a caveat.
- **The aborted trial left the run lock behind, and every push was refused.** The
  lock was taken 27 lines before the cleanup trap was installed, so an abort in
  between never released it, and nothing could tell a dead run's lock from a
  live one. Now the release is armed before the lock is taken; the bench records
  its PID in `<run>/bench.pid` (a detached launch hands it to the child); and the
  bench, preflight, `make status` and the deploy hook treat a lock whose bench is
  not running as stale — the bench and the hook clear it, and say so.
  `tools/run-lock.sh [--clear]` shows or clears it by hand. The hook lives in the
  VM's `.git/hooks`, which a push does not update: re-run
  `./setup/06-git-deploy.sh` once to install it. `tests/run-lock-tests.sh`
  covers every state in all three copies of the test.
- **Detached runs died overnight and left the node on an arm.** Twice a
  launched study stopped with no `finished.json`, a stale lock and
  `config.toml -> config-gvpn-arm.toml`: the bench was killed before its
  cleanup (a SIGKILL, the OOM killer, or a logout's session kill, whose SIGTERM
  grace ran out during cleanup). `--detach` now starts the bench as a transient
  systemd unit, `gvpn-bench-<run>`, outside the SSH login. Its `ExecStopPost`
  (`bench/on-bench-exit.sh`) runs however the bench ends: if the cleanup did not
  finish it restores the network config, releases the lock, and records
  systemd's reason in `run.log` and `finished.json`; the report and `make status`
  show it. Without systemd the old nohup/setsid path is kept.
- **`make report` could not write into a run: `PermissionError … sessions.csv`.**
  The bench runs under sudo, so each run directory and everything in it was
  root's; `make report` runs as you. `gvpn_state_init` handed the state
  directory back only when it started, before any run existed. Now the bench
  hands its run directory back to the sudo user when it starts and again at
  cleanup, preflight does the same for the trial and for the study file it edits
  (`sed -i` under sudo replaced it with a root-owned file, which would have made
  the next push refuse), and `make arms` for the arms. The analyzer checks it can
  write its outputs first and names the one-line fix instead of a traceback.
- **`make report` picked the aborted trial** (`no summary.csv in …`): it chose
  the newest run directory, and a run that stops before its first session has
  none. It now picks the newest run with a `summary.csv`, and the analyzer,
  given an aborted run explicitly, says the run stopped before its first session
  and prints the last lines of its log.
- New suites: `tests/run-bench-tests.sh` runs the real `gvpn-bench.sh --trial`
  of the shipped study with the client, systemd and network stubbed, and checks
  the manifest, both arms' sessions, config rollback and the report, and the
  lock through a stale lock, a `--detach` launch and an abort.
  `tests/run-lint-tests.sh` syntax-checks every script and lists variables used
  without a default and never assigned (`tests/unbound.py`). Both fail on the
  original bug.

### Fixed — arms broke the node (exit 66)

- **Arms appended a duplicate `[connection.path_planner]`.** The packaged network
  configs already declare that table; TOML rejects a table declared twice, and
  `gnosis_vpn-root` maps every config error — unreadable, unparseable or unknown
  key — to exit 66. `lib/tomlmerge.py` now **merges** an arm's keys into existing
  tables and refuses to write anything that does not parse or does not carry the
  arm's values. `tests/run-config-tests.sh` renders every template against a base
  shaped like the packaged configs.
- **Arms were written through the `config.toml` symlink**, overwriting the packaged
  network config (the only copy), and `cp -a` "backups" were symlinks to the same
  file, so rollback restored nothing. Arms now get `config-gvpn-arm.toml` and the
  link is re-pointed; the packaged configs are never written to. Rollback is
  re-pointing the link, and every bench run ends with it.
  `tools/restore-config.sh` repairs a node the old behaviour damaged — moving the
  damaged file aside first, since `--force-confmiss` only restores a *missing*
  conffile and dpkg keeps a modified one on purpose.
- **Re-rendering after an arm was installed built arms on top of that arm.** The
  base is now the recorded original network config; a generated config is refused
  as a base.
- `tests/run-node-tests.sh` covers the whole lifecycle — damage, repair, render,
  install, re-render, roll back — with systemctl, dpkg and apt stubbed.

### Fixed — route counting would have voided every study

- **The route parser folded per-line cost into the route.** The planner logs
  `path=<route> cost=0.12 composite_weight=…`, and the route's display form can
  contain spaces. The analyzer's regex ran to the next comma, so a correctly
  pinned arm read as 12 routes over 12 lines and the report would have declared
  **THE PIN DID NOT TAKE**. `lib/routes.py` now parses a field to the next
  `name=`, and also reads the planner's own `candidates=` count; `use-arm.sh`,
  preflight and the analyzer all use it. The test fixture now emits the real line
  shape and fails on the old parser.
- **Planner DEBUG logging never took effect.** It was set with `Environment=` in a
  drop-in, but systemd applies `EnvironmentFile=` after `Environment=`, so the
  packaged `gnosisvpn.env`'s `RUST_LOG=info` won. It is now an `EnvironmentFile=`
  in the drop-in, read last. Preflight checks the running process's environment.

### Fixed — the pin check measured the wrong thing (would have voided every study)

- First real counts: `auto` 3 candidates / 9 paths, `pin-planner` 1 candidate /
  4 paths. The headline was `max(distinct paths, candidates)`, so the working pin
  read 4, preflight would have refused it and every report voided itself. Distinct
  paths over a window is **churn**: the planner rebuilds each destination's cache
  entry at every refresh (`fill` / `background-refresh` / `recompute`) and may
  pick a different single path. The pin check is now the **candidate set per
  draw**: `lib/routes.py` groups `weighted candidate path` lines into rebuilds
  (per destination, closing when `sampling_probability` reaches 1 or a path
  repeats) and combines that with the return draw's `candidates=`. Churn is
  reported separately. `tests/run-routes-tests.sh` replays both measurements.
- **The analyzer checked the pin on the best-performing arm**, whatever it was:
  when noise made `no-explore` win, its (correct) 6 candidates voided the run.
  The bench now records `pinned_arms` — arms whose config sets
  `max_cached_paths = 1` — and the pin is checked on exactly those. Verdicts name
  the winning arm instead of saying "Pinning the path …". A baseline drawing from
  a single candidate gets a caveat. The fixture now churns, so it fails on the
  old headline.

### Fixed — every connect failed on hosts with an off-link gateway

- On this VM the default route reaches its gateway only via `onlink`. In static
  routing the client first adds per-peer bypass routes, `<peer>/32 via <gateway>`,
  **without** `onlink`; the kernel's nexthop check refuses them with ENETUNREACH
  (decoded from the rejected netlink message in the client's log: RTM_NEWROUTE,
  `rtm_flags = 0`). Tunnel setup fails in `EstablishWgTunnel`, the worker exits,
  and the root restarts it — the node falls from `Ready` back to `Initializing`.
  `auto` does it too; it is not the arm.
- The kit's own SSH-bypass route failed the same way, and `install_ssh_bypass
  || true` disabled `set -e` for the whole function, so setup printed "policy
  route installed" over a missing route. SSH was never protected.
- The bypass script now adds `<gateway>/32 dev <wan> scope link` first, runs
  under `set -e`, is re-applied with `restart` (not `enable --now`, which does not
  re-run an active oneshot), and is verified; a failure stops setup.
  `gvpn_gateway_ok` sends the client's kind of request for a TEST-NET-3 address;
  setup, preflight and diagnose use it. `use-arm.sh` names the cause when the log
  shows it. `tests/run-routing-tests.sh` replays the request in a network
  namespace and asserts both the failure and the fix.
- Upstream: the client should copy the WAN route's `onlink` flag (or add a link
  route for the gateway) when it builds bypass routes.

### Fixed — `use-arm.sh --count` could never see a connection

- `status` prints the node state on line 1 and the connection (`Connected to UK
  (since …)`) on a later line after `---`. The rewritten count read only line 1,
  so every connect timed out at 180 s however well it went. It now reads both
  from one snapshot per poll, prints what `connect` itself answered (its
  route-health verdict on failure), and stops at the second time the node falls
  from `Ready` back to `Warmup`/`Initializing` — a node reset — with the log's
  own ERROR/WARN lines, instead of polling blind.

### Changed

- Defaults: `GVPN_CHANNEL=snapshot`, `GVPN_NETWORK=jura-prod`,
  `GVPN_PIN_VERSION=2026.09.24+build.012613`, in `gvpn.conf` and the shipped
  study. A study that assigns `GVPN_PIN_VERSION`, even empty, overrides
  `gvpn.conf`. Setup now reports an installed version that differs from the pin.

### Fixed — operations

- **Preflight queried the wrong package** (`gnosis-vpn-client`, not `gnosisvpn`),
  so `--pin-current` could not pin and the version check could not pass.
- **`use-arm.sh --count` truncated the service log** before each count, destroying
  the evidence of any earlier failure. It now reads from a byte offset.
- **Restart checks could call a crash-looping service healthy**: with
  `RestartSec=5s`, sampling `is-active` at 5 s can land just after an
  auto-restart. Health now also requires `NRestarts` unchanged. Every start runs
  `reset-failed` first, clearing systemd's "start request repeated too quickly".
- `00-vm-setup.sh` checks the config before restarting and names the problem
  instead of printing "Job for gnosisvpn.service failed".
- The docs had dropped the onboarding step (`gnosis_vpn-ctl start-client`), and
  described exit 66 as "the config was never read, so not a bad key" — the
  generic sysexits meaning, not this binary's. Both corrected.

### Removed

- `setup/03-fetch-sources.sh`, `setup/04-build-patched.sh`: a patched build is not
  needed — the planner is configurable through `[connection.path_planner]`.
- `setup/01-iperf-server.sh`: the default load source needs no second machine.
- The manual hopr-lib YAML path (`GNOSISVPN_HOPR_CONFIG_PATH`, `hopr.yaml`, the
  `30-arm.conf` drop-in), safe/module address handling and the preset-layering it
  needed. The YAML cannot set the planner (`protocol.path_planner` is
  `serde(skip)`), and the file mode is the one mode where the client does not
  apply `[connection.path_planner]` at all. Leftover files are deleted on install.
- Re-onboarding and faucet codes; `needs_fresh_identity` is honoured as a refusal.

### Earlier in this cycle

- `--trial` (the study shrunk to 1 cycle × 5 MB; un-scoreable by design) and
  `bench/preflight.sh` (checks → route gate → trial → floor calibration → launch).
- `--profile transfers` (30 × 25 MB, ~3 h for two arms); study files set every
  knob (`GVPN_ARMS`, `GVPN_CYCLES`, …; flag > study > profile).
- `tools/close-channels.py`: channel closes via the Safe module through blokli,
  with a startup ABI self-test and a single-channel canary before the rest.
- The `pin-cfg` / `pin-cfg-pinned` pair, differing only in the return leg.
- State outside the worktree; deploys blocked during a run; `BUILD.txt` moved to
  the state dir (a root-owned copy in the worktree blocked deploys).
- Analyzer: verdict first, 90 % bootstrap CIs, voids a run whose pin did not take,
  declines below 8 sessions per arm, refuses to score a trial.

## Before this

Kit built for hoprnet#8408. `docs/design.md` has the design and the corrections
it makes to the issue's premise.
