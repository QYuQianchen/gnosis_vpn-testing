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
- **`use-arm.sh --count` narrates instead of going silent.** It polled for up to
  five minutes — 120s for Ready, 180s for Connected — printing nothing, which is
  indistinguishable from a hang. It now prints each state change with elapsed
  time, caps every `ctl` call at 10s so a wedged socket is diagnosed rather than
  waited out, checks the destination exists in config.toml before waiting three
  minutes for one that does not, and names the last state it saw when it gives up.
  Two bugs fixed alongside: an already-connected node failed the Ready gate and
  was reported as broken, and under `set -euo pipefail` a `grep` matching nothing
  killed the script — silently, in exactly the case where the log has no
  candidate lines and the script most needs to say so. Zero candidate lines is
  now refused as a result rather than reported as a count of 0, because 0 and a
  genuine pin of 1 look alike to anyone skimming.
- **Faucet codes are no longer burned by a failed request.** `gvpn-bench.sh`
  appended a code to `faucet-codes.used` *before* checking the faucet's answer,
  so a timeout or an unreachable faucet permanently retired a code that was
  never spent. Now only an actual answer consumes one: a transport failure
  leaves it in circulation and fails the arm. Every attempt is recorded in
  `faucet-codes.log` with its outcome, and `tools/faucet-codes.sh` (`make codes`)
  reports how many are left, how many funded a node, how many the faucet
  refused, and how many never reached it — with `--release` to put back a code
  that was retired in error.
- **Arms are now a diff from the running config, not a fresh one.** Every planner
  arm hardcoded the edge-client preset, including `min_paths_anonymity_floor: 0`.
  But `auto` runs in generated mode, where the client applies that preset and
  *then* layers this node's `[connection.path_planner]` overrides on top; a
  manual-mode arm ignores those overrides entirely. The shipped network configs
  set `min_paths_anonymity_floor = 3` where the preset uses 0, so on such a node
  every arm differed from the control in two ways at once — and `no-explore`,
  whose entire purpose is to change one variable, was changing the candidate cap
  from 3 to 50 as well. `02-make-arms.sh` now layers preset → the node's own
  `[connection.path_planner]` → the arm's template, and the templates state only
  the key each arm is actually testing. (`narrow` is deliberately still a
  combination; its template says so.)
- **A fresh-identity arm can no longer share a run with other arms.** An
  allowlist constrains channels only while they are being opened, so `pin-cfg-*`
  re-onboards — and that new, one-channel identity belongs to the whole node, not
  to the arm. Every later session of every other arm then ran on it, so `auto`
  after the re-onboard was not the `auto` before it. Worse than a clean break:
  the strategy reopens channels over time, so the contamination faded gradually
  with nothing in the data marking where it ended. The bench now refuses the
  combination and says to run it as its own study; `--allow-identity-reset`
  overrides it with a warning recorded in the log.
- **`pin-cfg-*` no longer re-onboards.** It was marked `needs_fresh_identity` on
  the reasoning that an allowlist only constrains channels as they are opened, so
  the existing ones could not be changed. That was wrong: channel closure is an
  ordinary on-chain operation (`ChannelStatus::PendingToClose`), and nothing
  about retargeting your channels needs a new identity. What is true is narrower
  — `gnosis_vpn-ctl` exposes no channel commands and edgli's strategy only opens
  and tops up, never closes, so the kit cannot automate it. The arm now carries a
  `PREREQUISITE`: set the allowlist, then close the other outgoing channels via
  the Safe, then verify with `--count`. No faucet code, no lost funding, no new
  identity. The run-time guard is correspondingly weaker — a warning that the
  trimmed channel set is node-global and contaminates the control, rather than a
  refusal about identity.
- **`tools/close-channels.py`** — the channel close, automated. The node key is
  on disk and is authorised on the Safe's management module, so a close is an
  `execTransactionFromModule` the node can sign for itself; hopr-lib's own test
  states it: "The node key only signs, and pays the gas." Two earlier claims here
  were wrong and are retracted — that retargeting channels needs a new identity,
  and that it cannot be scripted.

  It is written not to trust itself, because its ABI could not be checked against
  deployed bytecode: every channel is read from the contract first, every
  transaction is simulated with `eth_call`, and only then is anything signed, and
  only with `--send`. A wrong ABI costs an error message rather than a
  transaction. It is non-interactive — `--send` is the deliberate act, so it
  drives from a test harness; a prompt there would not have been a safety feature
  but a failure mode, since without a TTY `input()` raises `EOFError` after the
  plan is built and simulated, which reads as a stall rather than a refusal.
  Replacing the human checkpoint: `--max-close` caps one run, `--keep` must name
  an actually-open channel so a bad peer list cannot strip the node bare, and an
  append-only audit log records each transaction before sending and again on
  receipt. The module fragment is additionally checked
  against Gnosis Safe's published `0x468721a7` selector at startup. No contract
  address is defaulted: `--channels` is required, since a plausible wrong address
  is how a transaction goes nowhere and looks like it worked.
- **`close-channels.py` reads through `blokli-inspector`.** It previously had to
  be handed `GVPN_KNOWN_PEERS` and `--channels`, because HoprChannels is keyed by
  channel id and a direct reader cannot enumerate a Safe's channels. Blokli
  indexes the chain and answers both: `query channel --safe-address` lists them,
  and `query chain-info` reports the deployed `channel_dst` and the closure grace
  period. So the peer list is gone entirely and `--channels` is now an override
  rather than a requirement. Counterparties come back as numeric key ids and are
  resolved through `query account --key-id`. Reads and writes are split on
  purpose — web3 is left only with nonce, gas, simulation and signing — and a new
  guard refuses to run when blokli and the RPC disagree about the chain id, since
  a plan built on one network and signed against another simulates fine and lands
  nowhere useful.
- **`close-channels.py` runs entirely through blokli; no RPC, no web3.**
  `query node-overview` returns outgoing channels already separated from incoming
  and with destinations resolved to addresses, `query chain-info` gives the
  deployed contract, grace period and gas price, `query tx-count` the nonce, and
  `tx --payload` broadcasts. web3 is gone: with blokli doing reads and broadcast,
  an RPC client would be a second source of truth about the same chain, and a
  plan built against one endpoint and signed against another fails in a way
  nobody notices afterwards. The only local dependency is `eth-account`, to sign.

  Losing `eth_call` lost the simulation that proved the encoding, so two things
  replace it. The ABI encoder is hand-written and **self-tests at startup**
  against vectors computed independently of it, with the module selector required
  to equal Safe's published `0x468721a7`. And the first close of a run is sent
  **alone as a canary**: the chain is re-read and that channel must actually have
  moved to `PendingToClose` before any others are sent. A wrong ABI costs one
  transaction's gas on one channel and stops — verified in testing, where a
  deliberately ineffective transaction reported "confirmed" and the canary still
  refused to continue.
- **`arms/_pin-cfg-pinned/`** — the partner `pin-cfg-*` was missing, and without
  it the arm answered nothing. `pin-cfg-*` was meant to isolate the forward leg
  by contrast with `pin-planner`, but those two differ in more than the leg: one
  runs on a trimmed node in generated mode, the other on a full node in manual
  mode. The honest contrast is against an arm identical to it except for the
  return draw, so `--pin-relay` now renders a pair — same allowlist, same trim,
  `max_cached_paths = 1` on one of them. The gap between them is the return leg
  and nothing else. The partner carries the allowlist too, deliberately: pairing
  a trimmed arm with one that lacks it would let the strategy reopen the closed
  channels during the other arm's sessions, un-trimming the node mid-study with
  nothing in the data marking where.
- **`docs/running-all-arms.md`** — the six arms are three studies, not one run,
  and the boundary is node-global state. Sequences them, says what each
  comparison answers, and includes the restore step, which is the one people skip
  and the one that makes every later measurement on that node suspect.
- **A study file's `GVPN_ARMS` was read by nothing.** `studies/*.conf` documented
  it and `docs/` told people to set it, but `gvpn-bench.sh` only accepted `-a`,
  so a study silently ran *every* directory in the arms dir instead of the arms
  it named. Harmless until `make arms --pin-relay` exists — after that, study 1
  would have silently included the `pin-cfg` pair, whose prerequisite trims the
  node's channels and contaminates every other arm in the run. The shape knobs
  had the same gap, so a study wanting 25 MB transfers had to carry its flags in
  someone's shell history, which is the thing `studies/` exists to prevent.
  `GVPN_MODE`, `GVPN_CYCLES`, `GVPN_DURATION`, `GVPN_REPS`, `GVPN_REP_GAP`,
  `GVPN_DL_BYTES`, `GVPN_UL_BYTES`, `GVPN_DL_SECONDS`, `GVPN_UL_SECONDS` and
  `GVPN_UDP_SECONDS` now fill in between flag parsing and the profile, giving
  flag > study file > profile.
- **`make dry` ignored the study's profile**, hardcoding `--profile soak`, so
  every study dry-ran as a 36-hour matrix regardless of what it asked for — and
  the dry run is the one chance to see the wall clock before committing to it.
- **`--profile transfers`** — 30 cycles, bytes mode, 25 MB each way, one transfer
  per session. Two arms against one exit is ~3 h, against ~36 h for the full
  `soak` matrix, and it measures the same headline number. The existing profiles
  ran either 35 minutes (too few sessions for a tail statistic) or 36 hours (the
  full arms × exits matrix) with nothing in between, which made the study look
  far more expensive than the question requires. Wall clock is
  `~3 min × arms × exits × cycles`; the transfers themselves are under half of
  the ~3 min, the rest being connect, settle and the cooldown that stops one arm
  inheriting the previous arm's SURB estimate and path cache.
  `studies/2026-09-24-transfers-25mb.conf` ships it.
- **`tests/mkrun.py` scenario `thin`** — five arms at five cycles, with arm
  profiles identical to the `win` scenario, so anything it gets wrong is
  sampling rather than configuration. It asserts what a thin run must do:
  decline to claim a result, and name the sample size in a caveat. At n=5 the
  bootstrap returns nothing (its minimum is 8), every interval disappears, and
  one arm's point estimate comes out sign-flipped — `no-explore` reads −74% from
  a profile configured to help. Worth a regression test because the failure is
  silent: the tables look entirely normal.
- **`--trial` / `--full`** — a first-class rehearsal mode. `--trial` keeps the
  study's arms, exits and load source and shrinks only the work (1 cycle, 1 rep,
  5 MB), so what it exercises is the real config path. A smaller `--profile`
  would have exercised a *different* configuration, which is how a rehearsal
  passes and the real run fails on its first cycle. The manifest records
  `trial: true` and the analyzer refuses to score such a run — the verdict reads
  `TRIAL RUN`, outranking even a large measured effect, because the failure
  being guarded against is a rehearsal's report being pasted into the issue as
  the study's result. Regression-tested against the `win` fixture.
- **`bench/preflight.sh`** (`make preflight` / `make launch`) — the whole path
  from "is this rig sound" to a detached run, gated stage by stage so a failure
  stops everything after it. It exists because the expensive failures here are
  silent: an arm whose yaml never loaded, a pin that did not take, a client that
  upgraded itself mid-study, a floor threshold chosen after the fact. Two of its
  checks are refusals rather than warnings — a `pin-cfg-*` arm in a normal study
  (its channel trim is node-global and contaminates every other arm), and a
  baseline that draws only one route (a one-channel node has no path diversity
  to lose, so every comparison would be void).
- **`preflight.sh --pin-current`** — pinning the version has to be a deliberate
  act, but *typing* it does not, and `2026.09.17+build.134506` is exactly the
  kind of string a transcription error survives in unnoticed until someone reads
  the manifest weeks later. The flag writes the installed version into the study
  file and says so. With it, `GVPN_DESTINATION` is the only field anyone types.
- **`docs/RUN-THE-TEST.md`** — the configure-and-run path in one document, since
  the existing docs split it across START-HERE, configuration and
  running-all-arms and left the reader assembling the order themselves.
- **`gvpn-analyze.py --emit-floor`** — prints the baseline's p25 and nothing
  else, so preflight can calibrate `GVPN_FLOOR_MBPS` through the same session
  parsing the report uses rather than a second implementation that could
  disagree with it.
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
