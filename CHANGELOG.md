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
- **Secret scan on commit.** `tools/scan-secrets.sh`, wired in by
  `tools/install-hooks.sh`, refuses addresses and peer IDs in staged content —
  including in files that are supposed to be tracked.
- **Faucet codes moved** to `$GVPN_STATE/secrets/faucet-codes`; `gvpn-bench.sh`
  looks there by default instead of at a repo-relative path.
- **`.onboarded` markers survive a re-render.** Previously re-running
  `02-make-arms.sh` to change a planner setting wiped the marker on a `pin-cfg-*`
  arm, so the next run treated it as never funded — destroying the funded
  identity and spending a faucet code with nothing to show for it.
- **`studies/`** — one tracked config per experiment, named in the report.
- **`results/`** — committed reports (markdown, summary.csv, manifest.json).
- **`tests/`** — the analyzer is checked against fabricated runs, including the
  case where the pin silently failed to take.
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
