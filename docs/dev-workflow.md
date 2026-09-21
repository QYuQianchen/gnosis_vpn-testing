# Working on this without friction

Three things that pay for themselves within an hour: key-based SSH, connection reuse, and
push-to-deploy. Plus how to switch the client build from a config file rather than a remembered
command.

---

## 1. Stop typing your password

```bash
# on the Mac — skip if you already have a key
ssh-keygen -t ed25519 -C "gvpn-bench"

ssh-copy-id "$CONTABO_20_VM_USR"          # the last time you type the password
ssh "$CONTABO_20_VM_USR" 'echo ok'        # should not prompt
```

If `ssh-copy-id` isn't installed:

```bash
cat ~/.ssh/id_ed25519.pub | ssh "$CONTABO_20_VM_USR" \
  'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'
```

On macOS, put the passphrase in the keychain once so the agent stops asking:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

### With a YubiKey

A hardware key changes one thing about this workflow: if it demands a touch per
authentication, the dozens of one-line `ssh host '...'` commands here become dozens of touches.
Connection multiplexing (§2) is what makes that bearable — one touch per `ControlPersist`
window instead of per command. Set that up first.

**GPG authentication subkey** (what "subkeys" usually means). Check you have one:

```bash
gpg --card-status                      # look for "Authentication key"
```

Point ssh at gpg-agent:

```bash
# ~/.gnupg/gpg-agent.conf
enable-ssh-support
default-cache-ttl-ssh 3600
max-cache-ttl-ssh 28800
```

```bash
# ~/.zshrc
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)
gpgconf --launch gpg-agent
gpg-connect-agent updatestartuptty /bye >/dev/null
```

```bash
gpgconf --kill gpg-agent && exec $SHELL -l
ssh-add -L                             # should list the authentication subkey
```

`ssh-add -L` already prints the line in `authorized_keys` format, so there is no key ID to hunt
for — pipe it straight across:

```bash
ssh-add -L | ssh "$CONTABO_20_VM_USR" \
  'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'
```

("The agent has no identities" means gpg-agent is not serving ssh yet — recheck
`enable-ssh-support` and `SSH_AUTH_SOCK`, with the key inserted.)

If you do want the key ID — to export a specific subkey, say — `gpg --list-keys
--keyid-format=long --with-subkey-fingerprints` and look for the subkey marked `[A]`:

```bash
gpg --export-ssh-key qianchen.yu@hoprnet.org   # gpg picks the [A]-capable subkey itself
gpg --export-ssh-key 1111222233334444!         # trailing ! forces that exact subkey
```

**FIDO2 instead**, if you would rather not involve GPG. The VM supports it — Ubuntu 24.04 ships
OpenSSH 9.6:

```bash
ssh-keygen -t ed25519-sk -O resident -O verify-required -C "gvpn-bench"
ssh-copy-id -i ~/.ssh/id_ed25519_sk.pub "$CONTABO_20_VM_USR"
```

`-O resident` keeps the credential on the key, recoverable elsewhere with `ssh-keygen -K`.
`-O verify-required` demands the PIN as well as the touch — drop it if that is more friction
than a test VM warrants.

Either way the VM side is just an `authorized_keys` line; nothing else in the kit changes.

## 2. Reuse the connection

This workflow runs a lot of one-line `ssh host '...'` commands, and each one otherwise pays a full
TCP + TLS + auth handshake. Connection multiplexing makes every call after the first essentially
instant.

```bash
mkdir -p ~/.ssh/sockets
cat >> ~/.ssh/config <<'EOF'

Host gvpn-vm
    HostName 13.140.130.179
    User deploy
    # Keep idle sessions from being reaped mid-command during a long run.
    ServerAliveInterval 30
    ServerAliveCountMax 6
    # One TCP connection shared by every ssh/scp/rsync to this host, held open
    # for 10 minutes after the last one exits.
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h:%p
    ControlPersist 10m
EOF
chmod 600 ~/.ssh/config
```

**Which identity line to add depends on where your key lives.**

A key file on disk:

```
    IdentityFile ~/.ssh/id_ed25519
```

A key on a YubiKey via gpg-agent — there is no file, so `IdentityFile` would fail with
`no such identity: ... No such file or directory`. Point at the agent instead:

```
    IdentityAgent /Users/you/.gnupg/S.gpg-agent.ssh
```

Get the literal path from `gpgconf --list-dirs agent-ssh-socket` and paste it in —
`ssh_config` does not expand `$(...)` or shell variables. `IdentityAgent` is worth preferring
over relying on `SSH_AUTH_SOCK`, because `git push vm main` may run from an editor or GUI that
never sourced your shell rc.

Verify before moving on:

```bash
ssh-add -L                                   # the key should be listed
ssh -v gvpn-vm 'echo ok' 2>&1 | grep -iE 'offering|authenticated'
```

Then everything is `ssh gvpn-vm`, `scp file gvpn-vm:`, `rsync -avz ./x/ gvpn-vm:x/`.

Two caveats worth knowing. A wedged master is cleared with `ssh -O exit gvpn-vm`. And when the
VM's tunnel breaks connectivity, the shared master dies and takes every session on it with it —
the same failure the SSH policy route exists to prevent, so it should not bite once that is in
place.

With a hardware key, raise `ControlPersist` to `4h` for a long working session if you would
rather touch the key once a morning than once every ten minutes. The trade is that the socket
stays usable by anything running as you on that Mac for that long.

## 3. Two remotes: GitHub for the team, the VM for deploys

```
  Mac (source of truth)
   ├── git push origin main  →  GitHub private repo   (history, review, colleagues)
   └── git push vm main      →  the VM                (deploys instantly)
```

The VM never needs GitHub credentials this way, which matters on a box that also holds a funded
HOPR identity.

### The VM side, once

```bash
cd ~/gvpn-8408
./setup/06-git-deploy.sh            # repo lives IN ~/gvpn-8408 (no second directory)
./setup/06-git-deploy.sh --bare     # or a separate ~/gvpn-8408.git, if you prefer
```

In-place is the default: `~/gvpn-8408/.git` with `receive.denyCurrentBranch=updateInstead`, which
is git's supported push-to-deploy mode.

**The wrinkle it handles for you.** `updateInstead` refuses any push that would overwrite an
*untracked* file — and on a VM where the kit was first copied by hand, every file is untracked, so
the very first push fails with `would be overwritten by merge`. The script installs a
`push-to-checkout` hook, git's designed override, which makes the pushed tree authoritative for
**tracked** paths while leaving everything else on disk alone:

| | |
|---|---|
| replaced by a deploy | `setup/` `bench/` `docs/` `README.md` `gvpn.conf` |
| never touched | `arms/` `bench-runs/` `faucet-codes` `BUILD.txt` |

That split is the safety story: a deploy cannot destroy a run in progress, the arm configs you
validated, your faucet codes, or the recorded build identity of the machine. Regenerating the arms
stays a deliberate `02-make-arms.sh`, never a side effect of pushing a typo fix.

The hook also restores executable bits and **syntax-checks every script on arrival** — finding a
broken paste at push time beats finding it at 3am in cycle 40 of a soak.

### The GitHub side, once

```bash
# on the Mac, from your local copy of the kit
cd /path/to/gvpn-8408
git init -b main                     # if it is not a repo yet
git add -A && git commit -m "kit"

gh repo create hoprnet/gvpn-8408-bench --private --source=. --remote=origin --push
# or, without gh:
#   create the empty private repo in the GitHub UI, then
#   git remote add origin git@github.com:hoprnet/gvpn-8408-bench.git
#   git push -u origin main

git remote add vm gvpn-vm:/home/deploy/gvpn-8408
git push -u vm main
```

Thereafter: edit → commit → `git push origin main` for the team, `git push vm main` to deploy.

### Pushing to both at once

```bash
git config alias.pushall '!f() { b=$(git rev-parse --abbrev-ref HEAD); git push origin "$b" && git push vm "$b"; }; f'
git pushall
```

GitHub first, VM second — deliberately. The VM is unreachable fairly often during tunnel testing,
and this ordering means the commit is safely on GitHub before the deploy is attempted, with a failed
deploy visible rather than silent.

The alternative is one remote with two push URLs:

```bash
git remote add all git@github.com:hoprnet/gvpn-8408-bench.git
git remote set-url --add --push all git@github.com:hoprnet/gvpn-8408-bench.git
git remote set-url --add --push all gvpn-vm:gvpn-8408
git push all main
```

**The moment any `--push` URL is added, the remote's fetch URL stops being used for pushes** — which
is why GitHub has to be listed explicitly as the first one. Adding the VM to an existing `origin`
without re-adding GitHub is a common way to make commits quietly stop reaching GitHub, and it also
makes `git push origin main` mean something different from what the rest of the team expects.

`git remote -v` shows what you actually have; the `(push)` lines are the ones that matter.

**Check what you are about to publish.** `.gitignore` already excludes `faucet-codes`,
`bench-runs/`, `arms/` and `BUILD.txt`, but a private repo is still a place secrets go to live
forever:

```bash
git ls-files | grep -iE 'faucet|secret|\.id$|\.pass$|\.safe$'    # expect no output
```

If anything shows up there, remove it from the index before the first push — `git rm --cached`.
Node identity files (`gnosisvpn-hopr.id`, `.pass`, `.safe`) live under `/var/lib/gnosisvpn`, not in
the kit, so they should never appear; the grep is there for the day someone copies one in to debug.

### Optionally, have the VM pull from GitHub instead

Only if you want the VM to fetch on its own — a scheduled update, or a second machine that nobody
pushes to directly. Use a **read-only deploy key**, not your account credentials:

```bash
# on the VM
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy -N "" -C "gvpn-vm deploy key"
cat ~/.ssh/github_deploy.pub
# GitHub → repo → Settings → Deploy keys → Add, WITHOUT write access

cat >> ~/.ssh/config <<'EOF'
Host github.com
    IdentityFile ~/.ssh/github_deploy
    IdentitiesOnly yes
EOF

cd ~/gvpn-8408
git remote add origin git@github.com:hoprnet/gvpn-8408-bench.git
git fetch origin && git reset --hard origin/main
```

A deploy key is scoped to the one repository and read-only, so a compromised VM cannot push to
your team's history. `git reset --hard` replaces tracked files and leaves the gitignored data
alone, the same as a push-to-deploy would.

---

## 4. Switching the client build

Everything lives in `gvpn.conf` at the kit root:

```bash
GVPN_CHANNEL=snapshot        # stable | snapshot | experimental
GVPN_NETWORK=jura-prod
GVPN_PIN_VERSION=            # exact apt version, or empty for the channel's newest
```

Then on the VM:

```bash
./setup/05-set-version.sh --show      # what is installed vs what is configured
./setup/05-set-version.sh --list      # every version apt can see
sudo ./setup/05-set-version.sh --apply
```

Or override without editing the file:

```bash
sudo ./setup/05-set-version.sh --channel snapshot --apply
sudo ./setup/05-set-version.sh --version 0.97.1 --apply
```

### Three ways this goes wrong, all handled by the script

1. **Re-running the installer without `--channel` selects stable.** On a snapshot install that is a
   silent *downgrade*, performed happily, because a plain `apt upgrade` would never move backwards
   on its own. `05-set-version.sh` always passes the channel explicitly.
2. **`00-vm-setup.sh` holds the package** so an unattended upgrade cannot swap the binary mid-soak.
   Any upgrade has to unhold first and re-hold afterwards; forgetting the re-hold reopens the hole.
   The script does both.
3. **A channel switch can move the client across release lines,** and the networks available differ
   per line (`stable`/`snapshot` → jura-prod, jura-dev; `experimental` → piz-palu-dev). If the
   configured network isn't in the target channel, the installer silently re-points the config at
   that channel's default — so your exit set can change underneath you. `--show` prints both the
   configured and the actual channel so you can see it.

### The part the script can't do for you

**Pin the build once a study is under way, and don't move it.** Every arm has to run on the same
binary, or the comparison is between versions rather than between routing modes — and interleaving
doesn't rescue you, because a mid-run upgrade splits the dataset at a point in time that correlates
with nothing you care about. Set `GVPN_PIN_VERSION`, commit it, and leave it alone.

Which build depends on the question:

- **stable** — what production users actually run. If you're explaining floors users hit *now*,
  this is the defensible choice.
- **snapshot** — the line about to ship. Better if the question is "will pinning help in the next
  release", and it may already contain fixes that change the answer.

Worth asking whoever's been merging whether session-layer changes have landed since 0.96.0 —
measuring an old build tells you about a problem that may no longer exist.

### After any version change

`HoprLibConfig` is `deny_unknown_fields`, and the pinned arms depend on `protocol.path_planner`
keys (`max_cached_paths`, `return_path_exploration`). If those were renamed between versions the
service **refuses to start** with the arm's `hopr.yaml` rather than warning. `05-set-version.sh`
restarts the service and greps the journal for you, and prints a reminder to re-validate the arms.

Results from before and after a version change are not comparable. Start a fresh run directory.
