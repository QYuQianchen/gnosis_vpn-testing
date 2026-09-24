#!/usr/bin/env bash
# lib/routes.py against log lines in the planner's real shape, including the
# two results measured on the test VM (auto: 12 lines / 9 paths / sets of 3;
# pin-planner: 6 lines / 4 paths / sets of 1). The regression it pins: counting
# distinct paths over the window scored a working pin as "4 routes", which
# would have voided every study.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$KIT/lib" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import routes

D = "0xexit"
def rebuild(paths, kind="fill", dest=D, probs=None, ansi=False):
    probs = probs or [1 / len(paths)] * len(paths)
    out = []
    for p, pr in zip(paths, probs):
        l = (f"2026-09-24T14:10:00Z DEBUG hopr_transport::path::planner: weighted candidate path "
             f'kind="{kind}" destination={dest} hops=1 path=0x{p} -> {dest} cost=0.1{p} '
             f"composite_weight=0.5 sampling_probability={pr:.4f} total_latency_ms=Some(40)")
        out.append(l.replace("path=", "\x1b[3mpath\x1b[0m=") if ansi else l)
    return out
def draw(n, dest=D):
    return [f"x DEBUG hopr_transport::path::planner: drawing return paths from tempered weights "
            f"destination={dest} count=4 candidates={n} distinct_relayers={n} temper=0.5 exploration=0.1"]

cases, fails = [], 0
def case(name, log, **want):
    global fails
    got = routes.scan("\n".join(log))
    bad = {k: (got[k], v) for k, v in want.items() if got[k] != v}
    fails += bool(bad)
    print(f"  {'FAIL' if bad else 'ok  '}  {name}" + (f"  got/want: {bad}" if bad else ""))

auto = []
for i, trio in enumerate([("a1","a2","a3"), ("a4","a5","a6"), ("a7","a8","a9"), ("a1","a4","a7")]):
    auto += rebuild(trio, kind="fill" if i == 0 else "background-refresh", probs=[0.5, 0.3, 0.2]) + draw(3)
case("auto as measured: 12 lines, 9 paths, sets of 3  -> candidates=3",
     auto, lines=12, candidates=3, forward=3, churn=9)

pin = []
for p in ("p1", "p2", "p2", "p3", "p4", "p4"):
    pin += rebuild([p], kind="background-refresh") + draw(1)
case("pin-planner as measured: 6 lines, 4 paths, sets of 1 -> candidates=1",
     pin, lines=6, candidates=1, forward=1, churn=4, rebuilds=6)

inter = []
for x, y in zip(rebuild(("a1","a2","a3"), dest="0xUK"), rebuild(("b1","b2"), dest="0xUS")):
    inter += [x, y]
inter += rebuild(("a1","a2","a3"), dest="0xUK")[2:]
case("two destinations interleaved -> sets are kept apart",
     inter, forward=3, destinations=2)

case("zero-weight single candidates (probability 0) -> a repeated path closes the set",
     rebuild(["z"], probs=[0.0]) * 4, forward=1, rebuilds=4, churn=1)
case("ANSI-coloured field names",
     rebuild(("c1","c2"), ansi=True), forward=2, churn=2)
case("no planner lines -> nothing counted, not 'one route'", [], lines=0, candidates=0)
sys.exit(1 if fails else 0)
PY
rc=$?
echo; [ $rc = 0 ] && echo "all routes tests passed" || echo "FAILURES above"; exit $rc
