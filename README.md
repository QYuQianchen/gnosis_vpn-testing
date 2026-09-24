# #8408 benchmark kit

Does pinning the path raise Gnosis VPN's performance floor? This kit measures
pinned against automatic path finding on a dedicated Ubuntu VM, interleaving the
arms so time-of-day load cancels, and reports the slow tail with confidence
intervals rather than a mean.

**Start with [`docs/run.md`](docs/run.md)** — every step, in order, with a repair
section. The short version, on the VM:

```sh
sudo ./setup/00-vm-setup.sh --network jura-prod --allow-insecure
gnosis_vpn-ctl start-client 60m                         # onboard; wait for Ready
make arms && make count ARM=auto && make count ARM=pin-planner   # many, then 1
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --pin-current --trial-only
make launch STUDY=2026-09-24-transfers-25mb             # ~3 h, detached
make report
```

| Doc | For |
|---|---|
| [`docs/run.md`](docs/run.md) | set up, run, read the result, repair a broken node |
| [`docs/studies.md`](docs/studies.md) | how long a study takes and why; all six arms as three studies |
| [`docs/design.md`](docs/design.md) | why the experiment is shaped this way; what the code actually does |
| [`CHANGELOG.md`](CHANGELOG.md) | what changed between kit versions that could move a number |

## The arms

| Arm | Changes | Isolates |
|---|---|---|
| `auto` | nothing — the node's network config | control |
| `pin-planner` | `max_cached_paths = 1`, `return_path_exploration = 0` | one path, forward **and** return |
| `no-explore` | `return_path_exploration = 0` | the random return draws, alone |
| `narrow` | ≤ 3 candidates, untempered weights, no random draws | a shippable middle ground |
| `zero-hop` | `hops = 0` | the ceiling: no relay at all |
| `pin-cfg-<relay>` + `pin-cfg-pinned-<relay>` | node trimmed to one channel; the second also pins the return leg | the return leg's share (a pair; its own study) |

Each arm is a few keys in `arms/<name>/config.append`. `make arms` **merges**
them into the node's own network config — which already has a
`[connection.path_planner]` table — and refuses to write anything that does not
parse. Arms run in the client's generated mode, where
`PathPlannerOptions::apply()` layers these keys on the edge-client preset, so an
arm differs from `auto` in exactly the keys it names.

## Layout

```
gvpn.conf                  machine defaults (network, exit, load source)
studies/<date>-<name>.conf one file per experiment: arms, exits, size, pinned version, floor
arms/<name>/               arm templates: hops, config.append, README -- no addresses
lib/common.sh              paths, config loading, arm install/rollback, service restart
lib/tomlmerge.py           render an arm config by merging; check that a config parses
lib/routes.py              count routes from the planner's DEBUG lines
setup/00-vm-setup.sh       prepare the VM: client, SSH bypass, logging, flags   [once]
      02-make-arms.sh      render arm templates into ~/gvpn-state/arms
      05-set-version.sh    pin or switch the client version
      06-git-deploy.sh     make the VM a git push target                       [once]
bench/preflight.sh         checks -> trial -> floor calibration -> launch
      use-arm.sh           install one arm by hand; --count checks the pin took
      gvpn-bench.sh        the interleaved runner
      gvpn-analyze.py      the report
tools/diagnose.sh          why the service will not start (read-only)
      restore-config.sh    reinstall a damaged packaged network config
      close-channels.py    trim channels via the Safe, through blokli (study 2)
      backup-identity.sh   encrypted identity backup
      scan-secrets.sh, install-hooks.sh, fix-worktree-ownership.sh
tests/                     make test: config, node lifecycle, routing, analyzer, scanner
```

Two things live **outside** the repo, in `~/gvpn-state/`: run output and rendered
arms. A deploy rewrites the worktree, so nothing irreplaceable is kept in it.

How arms touch the client's config: `/etc/gnosisvpn/config.toml` is a symlink the
installer uses to pick a network. Installing an arm writes
`config-gvpn-arm.toml` and re-points the link; the packaged network configs are
never written to. Rollback re-points it back, and every run ends that way.

## Reading a result

The report opens with a verdict and four numbers. Before quoting it: the pinned
arm's `candidate paths` must be 1 (the report voids itself otherwise); bracketed
ranges are 90 % bootstrap CIs, and one spanning zero means no difference at that
sample size; the headline is the **floor rate and slow 10 %**, not the median.

## Safety and limits

A full-tunnel VPN on a remote VM removes your own SSH path. `00-vm-setup.sh`
installs a policy route keeping traffic from the VM's public IP off the tunnel
(a deliberate privacy hole — test VMs only), and `gvpn-bench.sh` runs a dead-man
switch that disconnects on a deadline or if the script dies. Verify SSH survives
a connect by hand before any long run, and keep the console reachable.

Relay-side metrics need operator access to the relays, so the "relays are
saturated" hypotheses cannot be tested here — only the path-selection ones. One
client per host.
