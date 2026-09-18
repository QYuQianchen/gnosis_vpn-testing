# Getting the kit onto the VPS, and what (if anything) to build

Short version: **the benchmark needs no build.** The client comes from APT and every pinned arm is
pure configuration. Source and compilation matter only for reading the code while interpreting
results, and for the optional Phase 4 patch.

---

## 1. Upload

The kit is one tarball, `gvpn-8408-kit.tar.gz`. Download it from the chat to your Mac, then:

```bash
VM="$CONTABO_20_VM_USR"        # e.g. deploy@<ip> — mind the $, see below

scp gvpn-8408-kit.tar.gz "$VM":~/
ssh "$VM" 'tar xzf ~/gvpn-8408-kit.tar.gz -C ~ && cd ~/gvpn-8408 && chmod +x setup/*.sh bench/*.sh bench/*.py && ls -R'
```

Verify it arrived intact — a truncated script that half-runs on a VPN host is not a fun afternoon:

```bash
shasum -a 256 gvpn-8408-kit.tar.gz              # on the Mac
ssh "$VM" 'sha256sum ~/gvpn-8408-kit.tar.gz'    # on the VM — must match
```

**Two ways this goes wrong, both of which look like a hang rather than an error.**

*Forgetting the `$`.* `scp file CONTABO_20_VM_USR:~/` contains a colon, so scp reads everything
before it as a *hostname* and goes off to resolve `CONTABO_20_VM_USR`. Depending on the resolver
that fails immediately or sits there for a long time. Confirm the variable first:

```bash
echo "$CONTABO_20_VM_USR"      # expect user@host, no stray quotes or spaces
```

*Writing somewhere you don't own.* If you log in as `deploy`, your home is `/home/deploy` and
`/root/` is not yours. Use `~/` and let the shell on the far side expand it.

**If scp stalls but `ssh` works**, push the bytes through a plain command channel instead — this
bypasses the SCP/SFTP subsystem entirely, which is where most of these hangs live:

```bash
ssh "$VM" 'cat > ~/gvpn-8408-kit.tar.gz' < gvpn-8408-kit.tar.gz
ssh "$VM" 'sha256sum ~/gvpn-8408-kit.tar.gz'
```

Other cheap things to try, in order of how often they are the answer: `scp -O` (forces the legacy
protocol — macOS 13+ runs scp over SFTP by default, and a missing or broken `Subsystem sftp` hangs
scp while leaving ssh perfectly fine), `scp -o IPQoS=none` (networks that drop OpenSSH's
DSCP-marked packets), and `ssh "$VM" 'echo hi' | xxd` (must print exactly `hi` — any banner, motd
or `.bashrc` output corrupts the SCP protocol).

**Iterating.** Once you start editing scripts locally, `rsync` beats repeated `scp` — it only sends
what changed and preserves the executable bit:

```bash
rsync -avz --chmod=F755 ./gvpn-8408/ "$VM":gvpn-8408/
```

**SSH config** saves a lot of typing over a multi-day run, and `ServerAliveInterval` keeps idle
sessions from being reaped mid-command:

```
# ~/.ssh/config
Host gvpn-vm
    HostName <VM_PUBLIC_IP>
    User deploy
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

Then `ssh gvpn-vm`, `scp file gvpn-vm:`, `rsync -avz ./gvpn-8408/ gvpn-vm:gvpn-8408/`.

**Alternative if you'd rather not copy files by hand:** push the kit to a private repo and
`git clone` it on the VM. That also gives you a history of the edits you inevitably make to the
arm configs during the run, which is worth having when you write up the results.

**Getting results back:**

```bash
sudo chown -R deploy: ~/gvpn-8408/bench-runs   # on the VM: the runner writes as root
rsync -avz gvpn-vm:gvpn-8408/bench-runs/ ./bench-runs/
```

Expect this to be large if planner DEBUG logging is on — the per-session `gnosisvpn.log` slices are
the bulk of it. To pull only what the analyser needs:

```bash
rsync -avz --include='*/' --include='summary.csv' --include='manifest.json' \
      --include='iperf-*.json' --include='telemetry.prom' --exclude='*' \
      gvpn-vm:gvpn-8408/bench-runs/ ./bench-runs/
```

…but note that drops `gnosisvpn.log`, and with it the distinct-relay count. Pull the logs for at
least the sessions you end up writing about.

---

## 2. Running so the run survives you

`gvpn-bench.sh --detach` already re-execs detached and prints the run directory, so the run survives
losing SSH. Use it for anything longer than the smoke profile. `tmux` on top is still worth it for
watching:

```bash
ssh gvpn-vm
tmux new -s bench
sudo ./bench/gvpn-bench.sh -s <IPERF_HOST> --profile soak --arms-dir ./arms --detach
# prints e.g. ./bench-runs/20260911-140302
tail -f ./bench-runs/20260911-140302/run.log
# detach with Ctrl-b d; reattach later with: tmux attach -t bench
```

Two files to check on when you come back:

```bash
tail -20 bench-runs/<id>/run.log        # progress
cat      bench-runs/<id>/deadman.log    # empty is good — anything here means a stall fired
```

---

## 3. Pulling source

```bash
ssh gvpn-vm
sudo apt-get install -y git
cd ~/gvpn-8408
./setup/03-fetch-sources.sh --out ~/src   # NO sudo
```

That clones four repositories:

| Repo | Why |
|---|---|
| `gnosis/gnosis_vpn-client` | the client, worker and ctl |
| `gnosis/gnosis_vpn` | packaging — installer, systemd unit, `linux/resources/config-jura-prod.toml` |
| `hoprnet/edge-client` | edgli; `src/lib.rs:59` is `latency_path_planner_config()` |
| `hoprnet/hoprnet` | hopr-lib and the transport — where the path draw lives |

**The revisions are not arbitrary, and the script does not hardcode them.** The client pins edgli
and hopr-utils-session by git revision, and edgli pins hopr-lib by revision in turn. The script
reads those out of the client's own `Cargo.toml`, checks them out, and cross-checks that edgli's
hopr-lib pin agrees with the client's hopr-utils-session pin. If they disagree it says so, because
that mismatch is what later produces a bewildering type error. (At the revisions current when this
was written, both resolve to hoprnet `87f0e07` — consistent.)

**One trap worth knowing about**, because it bites the obvious approach: the pinned revisions are
often *not on any branch*. The client currently pins edgli at `d3da1f6`, a merge commit whose branch
has since moved on, so `git clone` followed by `git checkout d3da1f6` fails with
`fatal: reference is not a tree` — from a full clone too, since the commit is unreachable from any
ref. GitHub will still serve it if you ask for the SHA directly:

```bash
git fetch origin d3da1f618cd282ad19725871021fa1920d2a52ba
git checkout FETCH_HEAD
```

`03-fetch-sources.sh` does this automatically when a plain checkout fails. If you clone by hand and
hit that error, this is why — the commit isn't missing, it's just unreferenced.

To read the code for the exact version you're *running* rather than `main`:

```bash
gnosis_vpn-ctl -V                                    # e.g. 0.96.0
./setup/03-fetch-sources.sh --out ~/src --client-ref v0.96.0
```

Three files carry most of what matters for this work:

```bash
less ~/src/hoprnet/transport/hopr/src/path/planner.rs    # PathPlannerConfig + the draw
less ~/src/hoprnet/transport/hopr/src/path/selector.rs   # candidate generation
less ~/src/hoprnet/hopr/hopr-lib/src/config.rs           # HoprLibConfig — the hopr.yaml schema
```

That last one is the authority on what may go in the manual `hopr.yaml`. It is
`deny_unknown_fields`, so anything not in that struct stops the service at start.

---

## 4. Building — Phase 4 only

Read this before deciding to build at all:

> **Do not build on the test VM while a run is in progress.** This compiles roughly 2000 crates
> across hoprnet and edgli: 30–90 minutes, several GB of RAM at link time, and 20+ GB in `target/`.
> Compiling next to a throughput measurement corrupts the measurement. Build before the run, or on
> another machine of the same architecture, and copy the two binaries across.

> **Build unpatched first.** The biggest risk in Phase 4 is "does this tree build on this box at
> all", not the patch. Prove the toolchain on the pinned sources before writing a line of patch.

```bash
# 1. toolchain and native deps (rustup, clang, libmnl-dev, libnftnl-dev, ...)
sudo ./setup/04-build-patched.sh --deps
. "$HOME/.cargo/env"

# 2. build the pinned sources, unmodified — proves the toolchain
./setup/04-build-patched.sh --src ~/src

# 3. ... apply the patch (see below), rebuild ...

# 4. install over the packaged binaries; originals kept as /usr/bin/<name>.apt
sudo ./setup/04-build-patched.sh --src ~/src --install

# undo at any point
sudo ./setup/04-build-patched.sh --src ~/src --restore
```

`rust-toolchain.toml` pins the channel (1.98), so rustup selects it automatically inside the repo —
don't install a toolchain by hand. `.cargo/config.toml` already sets `--cfg tokio_unstable` for
`[build]`; if anything in your environment has set `CARGO_BUILD_RUSTFLAGS` it **replaces** `[build]`
rather than merging, and the script re-adds the tokio flags for that case.

If cargo fights you, the repo's supported path is Nix, and it produces the same static binaries the
`.deb` ships:

```bash
sh <(curl -L https://nixos.org/nix/install) --daemon
cd ~/src/gnosis_vpn-client && nix build -L .#binary-gnosis_vpn-x86_64-linux
# result/bin/gnosis_vpn-{root,worker,ctl}
```

Slower to set up, much harder to get wrong.

### The patch, and the one trap in it

The change is to re-expose explicit intermediate paths, which the planner already honours
(`planner.rs:614` — *"an explicit path resolves to itself"*) but which `hopr-lib`'s public
`HopRouting` deliberately hides:

1. `hoprnet/hopr/hopr-lib/src/lib.rs` — `HopRouting` becomes an enum behind an `explicit-path`
   feature, with `From<HopRouting> for RoutingOptions` mapping the new variant to
   `RoutingOptions::IntermediatePath`. Keep `hop_count()` working for both variants —
   `route_health.rs` and `Destination::pretty_print_path` call it.
2. `gnosis_vpn-client/gnosis_vpn-lib/src/config/v6.rs` — re-accept
   `path = { intermediates = [...] }`. The v4 parser already had this; restore that arm rather than
   writing new code.
3. `gnosis_vpn-client/Cargo.toml` — add `[patch]` entries pointing `edgli` and `hopr-utils-session`
   at the local checkouts. **Never edit the pinned `rev` in place.**

The trap, which the client's own `Cargo.toml` already warns about in a comment:

> Cargo treats `?branch=X#sha` and `?rev=sha` as *different sources* even for byte-identical
> commits. Mix the two forms and the workspace builds hoprnet twice, then fails with
> `expected hopr_lib::HoprSessionClientConfig, found HoprSessionClientConfig`.

Both `edgli` and `hopr-utils-session` must end up on the same hoprnet source, in the same form.
`03-fetch-sources.sh` checks the two pins agree and warns if they don't.

After installing a patched build, **write down what you ran**:

```bash
gnosis_vpn-ctl -V
git -C ~/src/gnosis_vpn-client log -1 --format='%H %s'
git -C ~/src/gnosis_vpn-client status --porcelain    # must be clean, or the diff is unreproducible
```

A patched binary whose provenance isn't recorded produces a result nobody can reproduce, including
you in three weeks.

---

## 5. Order of operations, end to end

Written for a non-root login (`deploy`), which is the normal Contabo setup. **What takes `sudo` and
what must not is not cosmetic**: `sudo` changes `$HOME` to `/root`, so a source checkout or a
toolchain install under `sudo` lands somewhere your build cannot see it.

```bash
# Mac
scp gvpn-8408-kit.tar.gz "$CONTABO_20_VM_USR":~/
ssh "$CONTABO_20_VM_USR" 'tar xzf ~/gvpn-8408-kit.tar.gz -C ~ && cd ~/gvpn-8408 && chmod +x setup/*.sh bench/*.sh bench/*.py'

# VM under test
cd ~/gvpn-8408
sudo -v                                               # authenticate once; see note below
sudo ./setup/00-vm-setup.sh --network jura-prod --allow-insecure
gnosis_vpn-ctl start-client 60m                       # no sudo
watch -n5 gnosis_vpn-ctl status                       # wait for Ready

# second VPS
sudo ./setup/01-iperf-server.sh --allow-from <VM_PUBLIC_IP>

# VM — verify SSH survives a connect. Do not skip.
gnosis_vpn-ctl connect USA
#   from a third machine: ssh "$CONTABO_20_VM_USR" 'echo still-here'
gnosis_vpn-ctl disconnect

# VM — arms, validate, smoke
sudo ./setup/02-make-arms.sh --out ./arms --destination USA
#   follow the validation steps 02-make-arms.sh prints
sudo ./bench/gvpn-bench.sh -s <IPERF_HOST> --profile smoke --arms-dir ./arms
python3 ./bench/gvpn-analyze.py ./bench-runs/<newest>     # no sudo

# VM — the real run
tmux new -s bench
sudo ./bench/gvpn-bench.sh -s <IPERF_HOST> --profile soak --arms-dir ./arms --detach

# optional, Phase 4 only, never during a run
./setup/03-fetch-sources.sh --out ~/src                # NO sudo — or it clones into /root
sudo ./setup/04-build-patched.sh --deps                # apt as root, rustup as you
. "$HOME/.cargo/env"
./setup/04-build-patched.sh --src ~/src                # NO sudo
sudo ./setup/04-build-patched.sh --src ~/src --install # only this step needs root
```

**Sudo with a password is fine.** `sudo ./bench/gvpn-bench.sh` authenticates once at launch and the
script then runs as root for its whole life — the `--detach` re-exec and the watchdog it spawns
inherit that, and nothing inside ever calls `sudo` again. So `sudo: a password is required` from
`sudo -n true` is not a blocker; type the password at launch and the detached run continues without
further prompts. Refresh the timestamp with `sudo -v` immediately before starting a soak, and launch
from `tmux` so the run is not tied to the SSH session. NOPASSWD is optional convenience, not a
requirement — and it is a real privilege change on a box that will hold a funded HOPR identity.

**Result ownership.** `sudo ./bench/gvpn-bench.sh` writes `bench-runs/` as root inside your home, so
before rsyncing results back: `sudo chown -R deploy: ~/gvpn-8408/bench-runs`.

**`04-build-patched.sh --deps` handles the split for you**: apt packages go in system-wide as root,
while rustup is installed for `$SUDO_USER` — so `/home/deploy/.cargo`, not `/root/.cargo`. Source
`~/.cargo/env` in the shell you build from, and build *without* sudo.
