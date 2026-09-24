# Configure and run

## What you provide

One field you type. One you set with a flag. One the kit measures.

```sh
gnosis_vpn-ctl destinations      # on the VM — what your exits are called
```

```sh
# gvpn.conf — machine defaults, edited once
GVPN_DESTINATION=UK              # ← the only value you type, if yours differs
```

Everything else in `gvpn.conf` has a working default: channel `stable`, network
`jura-prod`, Cloudflare as the load source (no second VPS needed), 200M×20 log
rotation. Leave `GVPN_PIN_VERSION` empty here — it belongs per-study.

```sh
# studies/2026-09-24-transfers-25mb.conf — ships ready, ~3 h
GVPN_PROFILE=transfers           # 30 cycles, 25 MB each way, 1 transfer/session
GVPN_ARMS="auto pin-planner"
GVPN_DESTINATIONS="UK"           # same name as above

GVPN_PIN_VERSION=                # ← --pin-current fills it
GVPN_FLOOR_MBPS=                 # ← preflight measures it
```

Leave the last two empty. Preflight writes both back to the file, so the study
records what actually ran; commit it afterwards.

**These two are the ones that produce a plausible-but-meaningless result rather
than failing.** An unpinned version means each arm installs whatever is newest
when it runs, and you compare versions instead of routing modes — with tables
that look entirely normal. A floor threshold chosen after seeing the pinned arm
makes the headline number whatever you wanted. Neither is yours to type.

No faucet codes are needed; no shipped arm re-onboards.

## Deploy

```sh
# Mac
make push
```

`make push` is refused while a run is in progress — a deploy rewrites scripts in
place and bash reads a script as it executes.

## Prepare the node — once

```sh
ssh gvpn-vm && cd ~/gvpn-8408

# 1. the VM itself: client, policy route, planner DEBUG logging, log rotation
sudo ./setup/00-vm-setup.sh --network jura-prod --allow-insecure

# 2. ONBOARD. The service being active is not the same as the client running:
#    systemd starts the daemon, this starts the client, and until it reaches
#    Ready the node has no identity, no channels and no destinations.
#    The daemon must be up FIRST -- start-client talks to it over a socket and
#    answers "service not running" if it is not:
systemctl is-active gnosisvpn || sudo journalctl -u gnosisvpn -n 20 --no-pager
gnosis_vpn-ctl start-client 60m
watch -n5 gnosis_vpn-ctl status        # wait for Ready before anything else

# 3. back up the funded identity, now that there is one
make backup

# 4. render the arms — needs the node's own addresses, so it must come after (2)
sudo -E ./setup/02-make-arms.sh
```

Step 2 is the one people skip, because `systemctl is-active gnosisvpn` looks
like success. It is not: onboarding is what creates the identity the rest of
the kit depends on, and step 4 reads addresses that do not exist until it has
finished.

## Run

```sh
# a. pin the version, rehearse the study end to end        ~10 min
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb \
     --pin-current --trial-only

# b. calibrate the floor, launch detached                  ~25 min, then ~3 h
sudo -E ./bench/preflight.sh --study 2026-09-24-transfers-25mb --launch -y

# c. read it
make status
make report
make publish STUDY=2026-09-24-transfers-25mb
```

After (b) you can close the laptop. `results/<study>/report.md` is what goes
into the issue.

### What preflight checks

Each stage gates the next; it exits non-zero at the first hard failure, so
`--launch` cannot fire after a failed check.

| Stage | Time | Catches |
|---|---|---|
| **A** static | seconds | unrendered arms, placeholders, service down, version not pinned, `zero-hop` without `--allow-insecure`, planner DEBUG off, policy route missing, run already in progress, a `pin-cfg-*` arm in a normal study |
| **B** route gate | ~3 min/arm | an arm whose config the client rejects. Asserts `pin-planner` = 1 route and the baseline > 1 |
| **C** trial | ~1 min/arm | data actually moving, every arm producing a session, the report rendering |
| **D** calibrate | ~25 min | runs the **baseline alone**, writes its p25 into the study as `GVPN_FLOOR_MBPS` |
| **E** launch | — | detached, survives your SSH closing |

`--trial` is the study *shrunk* — same arms, same exits, same load source, 1
cycle × 5 MB. Not a smaller profile, which would exercise a different
configuration and pass while the real run fails on its first cycle. A trial's
manifest records `trial: true` and the analyzer refuses to score it.

## Verify by hand

Two things preflight cannot do for you.

```sh
# the load endpoints, tunnel up — both must print 200
curl -s -o /dev/null -w '%{http_code}\n' \
     "https://speed.cloudflare.com/__down?bytes=1000000"
head -c 1000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' \
     --data-binary @- "https://speed.cloudflare.com/__up"

# SSH survives a tunnel connect — preflight checks the route exists, not that it works
ip rule show | grep 200 && ip route show table 200    # BOTH non-empty
gnosis_vpn-ctl connect UK
#   from a third machine:  ssh <user>@<VM IP> 'echo still-here'
gnosis_vpn-ctl disconnect
```

A rule pointing at an empty table is the worst state: it looks configured and
protects nothing. Keep the Contabo console reachable.

## When it fails

```sh
sudo ./tools/diagnose.sh        # or: make diagnose
```

One read-only report: exit status decoded, the unit and every drop-in, the env
files, the config and its tables, every absolute path they name marked present
or missing, the identity directory, and the binary's own output unfiltered.
Addresses and keys are redacted, so it is safe to paste. Start here rather than
with a single `journalctl` — these facts are useless one at a time.


| Symptom | What it is |
|---|---|
| `the study sets no GVPN_PIN_VERSION` | add `--pin-current`, or pick one with `05-set-version.sh --list` |
| `THE CLIENT REJECTED THIS ARM'S CONFIG` | a key this build does not know. The error's "expected one of …" is the authoritative list for *this binary*. `use-arm.sh` has already rolled back |
| `auto drew 1 route` | the node holds one channel — the baseline has no diversity to lose, so every comparison is void |
| `pin-planner drew N routes` | the `[connection.path_planner]` override is not being applied; check the arm's `config.toml` |
| `SERVICE DID NOT START`, exit **66** | `EX_NOINPUT` — a file it needs could not be *opened*. The config was never read, so this is not a bad key. Check `systemctl cat gnosisvpn` for a drop-in naming a file that no longer exists, and `ls -l /etc/gnosisvpn/`. Repair with `sudo ./setup/00-vm-setup.sh --network <net>`, which rewrites the unit, the drop-ins and the config |
| `ctl` says `service not running` | the daemon is down, so nothing the client can do will help. Fix the daemon first — this is never solved by re-running a `ctl` command |
| `SERVICE DID NOT START`, exit **78** | `EX_CONFIG` — the config *was* read and rejected. That is a bad key |
| `NO RESULT: no 'candidate path' lines` | planner DEBUG is off. Not "one route" — nothing was counted |
| `a run is already in progress` | `make status`; clear the lock only if stale |
| `unsubstituted placeholders` | the node had not onboarded when `make arms` ran |
| report says `THE PIN DID NOT TAKE` | the run compared `auto` with itself. Discard it |
| report says `TRIAL RUN` | you are reading a rehearsal |

## New kit version

```sh
# Mac
make status                                  # nothing running on the VM
tar xzf gvpn-8408-kit.tar.gz --strip-components=1 -C <your clone>
make test && git add -A && git commit -m "kit: <what changed>" && make push

# VM — only if an arm template or the hook changed
sudo -E ./setup/02-make-arms.sh
./setup/06-git-deploy.sh          # not as root
```

Read `CHANGELOG.md` first: a change
that moves a number means a study spanning it must be restarted, which is why
every run records `kit_rev`.
