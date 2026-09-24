# Changelog

A result is only interpretable against the kit revision that produced it; every
run's `manifest.json` records `kit_rev`. Entries here are for changes that can
move a number or break a node — not for docs or comments.

## Unreleased

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
