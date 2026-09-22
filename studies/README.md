# studies/

One file per experiment, sourced on top of `gvpn.conf`, stating only what differs.

```sh
GVPN_STUDY=2026-09-22-pin-vs-auto sudo -E ./bench/gvpn-bench.sh --detach
# or: make soak STUDY=2026-09-22-pin-vs-auto
```

A study file is what makes a result reproducible. Flags live in one person's
shell history; this is tracked, its name goes on the results directory, and the
run's manifest records the kit revision it was read at.

**Do not edit a study file after its run has started.** An edited study is one
whose arms were not all measured the same way, and nothing in the output would
say so. Copy it to a new date instead.
