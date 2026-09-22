# Changelog

A result is only interpretable against the kit revision that produced it. Every
run's `manifest.json` records `kit_rev`; this file says what changed between them.

Add an entry for anything that could move a number: arm planner settings, the
measurement method, the analysis, the profiles. Not for docs or comments.

## Unreleased

### Repository restructure

- **State moved out of the worktree.** Raw runs, rendered arms, faucet codes and
  identity backups now live in `$GVPN_STATE` (default `~/gvpn-state`). The repo
  can be replaced wholesale by a deploy without anything irreplaceable moving.
- **Arm templates split from instances.** `arms/` in the repo holds address-free
  templates and is tracked, so a changed planner setting shows up in a commit;
  `02-make-arms.sh` renders them into `$GVPN_STATE/arms` with this node's safe and
  module addresses substituted.
- **Deploys blocked during a run.** `gvpn-bench.sh` maintains `$GVPN_STATE/run.lock`;
  the push-to-checkout hook rejects a push while it exists. Previously a push
  mid-soak could corrupt the running bench or swap the analysis under a study.
- **Deploys refuse a worktree they cannot fully write.** A directory left by a
  `sudo` run is root-owned, and `git read-tree` fails partway through it with a
  message that names only the symptom — leaving the worktree half-deployed. The
  hook now checks ownership first and says what to move. (The check has to use
  an absolute path: `push-to-checkout` runs with cwd set to `.git`, not the
  worktree, so scanning `.` would silently always pass.)
- **Secret scan on commit.** `tools/scan-secrets.sh`, wired in by
  `tools/install-hooks.sh`, refuses addresses and peer IDs in staged content —
  including in files that are supposed to be tracked.
- **Faucet codes moved** to `$GVPN_STATE/secrets/faucet-codes`; `gvpn-bench.sh`
  looks there by default instead of at a repo-relative path.
- **`.onboarded` markers survive a re-render.** Previously re-running
  `02-make-arms.sh` to change a planner setting wiped the marker on a `pin-cfg-*`
  arm, so the next run treated it as never funded — destroying the funded
  identity and spending a faucet code with nothing to show for it.
- **`tools/backup-identity.sh`** (`make backup`) — encrypted identity backup and
  restore. Replaces a runbook `gpg -c` line that could not work: with `tar`
  occupying stdin on a headless box, gpg-agent has no terminal to prompt on and
  dies with `Inappropriate ioctl for device`. Uses `openssl enc` with the
  passphrase on a file descriptor: no agent, no keyring. It stops the service
  before reading the identity, verifies the archive by decrypting it, and on
  restore checks the archive before touching anything and keeps the identity it
  replaces.
- **`tools/fix-worktree-ownership.sh`** (`make fix-perms`) — clears the
  root-owned leftovers that block the first deploy after the restructure, moving
  them into the state directory where they belong. Idempotent; deletes nothing.
- **`studies/`** — one tracked config per experiment, named in the report.
- **`results/`** — committed reports (markdown, summary.csv, manifest.json).
- **`tests/`** — `make test` runs two suites. The analyzer is checked against
  fabricated runs, including the case where the pin silently failed to take. The
  secret scanner is checked against known leaks, under a shell with `mapfile`
  removed, because the pre-commit hook runs on macOS where bash is still 3.2.
  Two of its cases are regressions that shipped: a real address beginning
  `0xdead` was exempt (the benign-list was applied per line rather than per
  match), and only the first file of a commit was scanned (nested read loops
  shared stdin).
- **`lib/common.sh`** — one resolution of kit root, state dir and config, which
  fixes a latent bug: under `sudo`, `$HOME` is `/root`, so a `$HOME`-relative
  state path would have produced two state directories depending on invocation.

### Measurement and analysis

- `gvpn-bench.sh` 0.3.0 → 0.4.0: manifest now records the client service and
  package version, channel, network, kit revision and host congestion control;
  `finished.json` records the end time and exit code, so a soak that died at hour
  6 of 48 says so on its own report.
- `gvpn-analyze.py`: report restructured to lead with a verdict; 90% bootstrap
  confidence intervals on every comparison; a pinned arm still drawing multiple
  routes now voids the report rather than footnoting it; `--markdown` emits an
  issue-ready document; `--no-diagnostics` trims it.

## Before this

Kit built for hoprnet#8408. See `docs/plan.md` for the experiment design and the
three corrections it makes to the issue's premise.
