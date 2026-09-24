# Installing a new version of the kit

Same six steps every time. They take about two minutes.

The kit arrives as `gvpn-8408-kit.tar.gz`. It replaces tracked files in your
clone; it never touches `~/gvpn-state`, and it never touches the VM directly —
the VM only ever gets code through `git push`.

---

## 1 · MAC — check nothing is running on the VM

```sh
ssh gvpn-vm 'ls -l ~/gvpn-state/run.lock 2>/dev/null && echo "RUN IN PROGRESS" || echo "clear"'
```

If a run is in progress, stop here. Deploys are refused while it is, and for good
reason: a deploy rewrites script files in place, and bash reads a script as it
executes. Wait for it, or accept losing the run.

---

## 2 · MAC — extract over your clone

```sh
cd ~/path/to/parent-of-your-clone        # the directory CONTAINING gvpn-8408
tar xzf ~/Downloads/gvpn-8408-kit.tar.gz

cd gvpn-8408
git status --short
```

Read that `git status`. It is the whole diff of the new version against what you
had. If a file you edited locally shows up modified, `git diff <file>` before
going further — extraction overwrites, it does not merge.

Your own files are untouched by extraction only if they are not in the tarball.
`gvpn.conf` and `studies/*.conf` **are** in it, so:

```sh
git diff gvpn.conf studies/
```

If that shows your settings being reverted, re-apply them now. This is the one
step where a new version can quietly undo your configuration.

---

## 3 · MAC — run the tests

```sh
make test
```

Both suites, about ten seconds. They run against fabricated data, so they need
no VM and no network. If either fails, the version is broken — say so rather
than pushing it.

---

## 4 · MAC — commit and push

```sh
git add -A
git commit -m "kit: <what changed, from the CHANGELOG>"
make push
```

The pre-commit secret scan runs here. If it flags something, read it: the point
is that it catches addresses in files that are *supposed* to be tracked, which is
how a leak actually happens.

If the push is rejected, the message says why — a run in progress, or a
root-owned path in the worktree. For the second, on the VM: `make fix-perms`.

---

## 5 · VM — reinstall the deploy hook, if the hook itself changed

The hook is **generated** by `06-git-deploy.sh` at install time, not tracked. So
changes to it arrive in the repo but are not live until you regenerate them.

```sh
ssh gvpn-vm
cd ~/gvpn-8408
grep -q 'REFUSING TO DEPLOY' .git/hooks/push-to-checkout || ./setup/06-git-deploy.sh
```

Check the CHANGELOG for "hook" or "deploy" and re-run `./setup/06-git-deploy.sh`
if either appears. Running it again when nothing changed is harmless.

---

## 6 · VM — re-render the arms, if any arm template changed

```sh
ssh gvpn-vm
cd ~/gvpn-8408
make status
git log --oneline -1 -- arms/          # did the templates move?
```

If they did:

```sh
make arms
sudo ./bench/use-arm.sh pin-planner --count     # must read 1
```

Re-rendering preserves `.onboarded` markers, so it does not cost a faucet code.
But it **does** mean any completed run used different arm settings from the ones
now on disk — which is why every run records the kit revision that produced it,
and why a study that is half-finished should not be resumed across an arm change.
Start a new study instead.

---

## When you can skip steps

| Changed | Steps needed |
|---|---|
| docs only | 2, 4 |
| analysis (`gvpn-analyze.py`) | 2, 3, 4 — and re-run `make report` on existing runs; it re-reads raw data, so old runs get the new report |
| bench (`gvpn-bench.sh`) | 2, 3, 4 — takes effect on the next run |
| arm templates (`arms/`) | all six |
| deploy hook (`06-git-deploy.sh`) | 1–5 |
| `lib/common.sh`, paths | all six, and check `make status` on the VM |

The CHANGELOG's top section says which of these a given version touches.

---

## If a version turns out to be bad

Nothing here is irreversible. The VM's worktree is a checkout, the state
directory is untouched by deploys, and every run records the kit revision it ran
under.

```sh
# on your Mac
git log --oneline -5
git revert <bad commit>          # or: git reset --hard <good commit>
make push
```

On the VM, re-run `./setup/06-git-deploy.sh` if the hook was part of what you
reverted, and `make arms` if the templates were.

A run recorded under the bad version is not necessarily wasted — check its
`manifest.json` for `kit_rev` and decide whether the change affected what it
measured. The point of recording it is that you do not have to guess.
