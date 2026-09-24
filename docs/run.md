# Run it, step by step

`[Mac]` = your laptop, in your clone of the kit. `[VM]` = `ssh gvpn-vm`, in `~/gvpn-8408`.

> **Node down right now with exit 66?** Jump to [Repair](#repair-a-node-that-will-not-start).

---

## 0 · Before you start — once

| You need | |
|---|---|
| A VM | Ubuntu, ≥ 4 vCPU, ≥ 8 GB RAM, ≥ 40 GB disk (DEBUG logging is hungry) |
| Console access | the provider's VNC — a full-tunnel VPN can take your SSH with it |
| An SSH alias | `gvpn-vm` in `~/.ssh/config` on your Mac |

```
# ~/.ssh/config on your Mac
Host gvpn-vm
    HostName  <VM public IP>
    User      deploy
```

**The one value you may need to type:** your exit's name. On the VM,
`gnosis_vpn-ctl destinations` lists them; if yours is not `UK`, set
`GVPN_DESTINATION` in `gvpn.conf`. Everything else there has a working default.

## 1 · Deploy the kit

```sh
[VM]  ./setup/06-git-deploy.sh             # once: makes the VM a push target (not as root)
[Mac] git remote add vm gvpn-vm:gvpn-8408  # once
[Mac] make hooks                           # once per clone: pre-commit secret scan
[Mac] make push                            # every time the kit changes
```

A push is refused while a run is in progress — a deploy rewrites scripts as they
execute.

## 2 · Prepare the node — once

```sh
[VM] sudo ./setup/00-vm-setup.sh --allow-insecure
```

Channel, network and version come from `gvpn.conf` (`snapshot`, `jura-prod`,
`2026.09.24+build.012613`); flags override them. Installs the client, the SSH-bypass policy route (plus a link-scope route for
the gateway, which some hosts need — see Repair), planner DEBUG logging and log
rotation, then starts the service. If the bypass cannot be installed, setup
stops: a working tunnel would take your SSH with it. It checks the config first and stops with a
reason if it will not load.

```sh
[VM] gnosis_vpn-ctl start-client 60m
[VM] watch -n5 gnosis_vpn-ctl status       # wait for Ready -- this is onboarding
[VM] make backup                           # encrypt the funded identity; keep the passphrase
```

`systemctl is-active` is not enough: the daemon being up is not the client being
onboarded. Until `Ready`, there is no identity, no channels, no destinations.

**Check your SSH survives a tunnel** — preflight can check the route exists, not
that it works:

```sh
[VM]  gnosis_vpn-ctl connect UK
[Mac] ssh gvpn-vm 'echo still-here'        # from a SECOND terminal
[VM]  gnosis_vpn-ctl disconnect
```

## 3 · Render the arms and prove the pin

```sh
[VM] make arms                             # sudo -E ./setup/02-make-arms.sh
[VM] make count ARM=auto                   # must read MANY routes
[VM] make count ARM=pin-planner            # must read 1
```

`make arms` merges each arm's settings into the node's network config and
refuses to write anything that does not parse. `make count` installs the arm,
connects, pulls traffic for 90 s and counts the routes the planner used; if the
service will not start with that arm, it puts the network config back.

**Do not go further until `auto` reads many and `pin-planner` reads 1.** If both
read many, the pin is not taking effect and every later number is about nothing.

## 4 · Run a study

A study is one file in `studies/`. The one that ships — `2026-09-24-transfers-25mb`
— is 2 arms × 1 exit × 30 cycles of 25 MB, about 3 hours, pinned to
`snapshot` / `jura-prod` / `2026.09.24+build.012613`. Leave `GVPN_FLOOR_MBPS`
empty; preflight measures it.

```sh
[VM] sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --trial-only
```

Preflight refuses to run if the installed version differs from the pinned one,
so a mid-study upgrade cannot silently turn the comparison into one between
versions. (`--pin-current` instead writes whatever is installed into the study —
for starting a study on a new build.) `--trial-only` runs the whole study at
1 cycle × 5 MB and stops — same arms, same exits. A trial's report says
`TRIAL RUN` and cannot be quoted.

```sh
[VM] make launch STUDY=2026-09-24-transfers-25mb
```

Re-checks everything, calibrates the floor threshold from `auto` alone (so the
pinned arm cannot influence the bar it is judged against), writes it into the
study file, then starts the run detached. You can log off.

```sh
[VM] make status                           # still running?
```

At the end the node is put back on its network config automatically.

## 5 · Read and keep the result

```sh
[VM]  make report
[VM]  make publish STUDY=2026-09-24-transfers-25mb
[Mac] scp -r gvpn-vm:gvpn-8408/results/2026-09-24-transfers-25mb results/
[Mac] scp gvpn-vm:gvpn-8408/studies/2026-09-24-transfers-25mb.conf studies/
[Mac] git add results/ studies/ && git commit -m "results: …" && make push
```

`scp`, not `git pull`: `publish` leaves the report as untracked files on the VM,
and the study file there now carries the pinned version and floor that preflight
wrote. Copy it back **before your next push** — a push rewrites tracked files on
the VM and would overwrite those values. (Each run's `manifest.json` records them
too, so a run is never unidentifiable.)

`results/<study>/report.md` is what goes into #8408. Before quoting it:

- **`distinct routes` must be 1 for `pin-planner`.** If not, the report voids itself.
- **Bracketed ranges are 90 % confidence intervals.** One that spans zero means
  the arms are indistinguishable at that sample size.
- **The headline is the floor rate and the slow 10 %**, not the median.

For other shapes of study — more arms, more exits, the channel-trim pair — see
`docs/studies.md`.

---

## Repair a node that will not start

```sh
[VM] sudo ./tools/diagnose.sh              # read-only; safe to paste
```

The first section decodes the exit status. **Exit 66 means the config failed to
read *or parse*** — `gnosis_vpn-root` maps every config error to 66, including a
bad or duplicated key. The binary's own reason is in
`/var/log/gnosisvpn/gnosisvpn.log`, not in `journalctl`; diagnose shows it.

If the network config itself is damaged (diagnose says it does not parse, or
differs from the package):

```sh
[VM] sudo ./tools/restore-config.sh             # inspect
[VM] sudo ./tools/restore-config.sh --apply     # repair
[VM] sudo ./setup/00-vm-setup.sh --network jura-prod --allow-insecure
[VM] make arms
```

`--apply` keeps the damaged file as `config-<net>.toml.damaged-<time>`,
reinstalls the packaged one, re-points `config.toml` and restarts the service.
Your identity in `/var/lib/gnosisvpn` is never touched.

To put the network config back after an arm, without repairing anything:
`sudo ./bench/use-arm.sh --restore`.

| Symptom | Meaning |
|---|---|
| exit **66** | config failed to read or parse — see above |
| exit **75** | another instance holds the daemon lock |
| log: `static routing setup error … Network unreachable (os error 101)` | the gateway is **not on-link** (default route uses `onlink`). The client adds its peer bypass routes via the gateway without `onlink`, the kernel refuses them, tunnel setup fails, the worker restarts. Re-run `00-vm-setup.sh` — it adds `<gateway>/32 dev <wan> scope link`, which makes the gateway directly reachable. `tests/run-routing-tests.sh` reproduces this |
| node falls from `Ready` back to `Warmup`/`Initializing` after `connect` | the client is rebuilding its node, not connecting slowly. `use-arm.sh` stops at the second reset and prints the log's own errors. Run `make count ARM=auto` — if the control does it too, it is not the arm |
| `connect: Unable to connect to UK: …` / `Waiting to connect … once possible` | the text after the colon is the client's route-health verdict — that is the reason |
| `start request repeated too quickly` | systemd gave up after 5 failures; the kit's scripts clear this themselves (`systemctl reset-failed gnosisvpn`) |
| `service not running` from `gnosis_vpn-ctl` | the daemon is down; no `ctl` command can fix that — repair the daemon first |
| `NO RESULT: the planner logged no candidate paths` | planner DEBUG is not active; re-run `00-vm-setup.sh`. Not the same as 1 route |
| `auto` reads 1 route | the node holds one channel — the baseline has no diversity to lose, every comparison is void |
| `pin-planner` reads many | the override is not applied — `sudo ./bench/use-arm.sh --show` |
| push rejected, "not owned by deploy" | `./tools/fix-worktree-ownership.sh --apply` on the VM |
| report says `THE PIN DID NOT TAKE` | the run compared `auto` with itself; discard it |

## New version of the kit

```sh
[Mac] ssh gvpn-vm 'cd gvpn-8408 && make status'   # nothing may be running
[Mac] tar xzf gvpn-8408-kit.tar.gz --strip-components=1 -C <your clone>
[Mac] make test && git add -A && git commit -m "kit: …" && make push
[VM]  make arms                            # arms are rendered by the kit, so re-render
```

Read `CHANGELOG.md` first: a change that can move a number means a study that
spans it must be restarted. Every run records `kit_rev` for that reason.
