#!/usr/bin/env python3
"""
gvpn-analyze.py -- per-arm comparison for the pinned-vs-auto path benchmark (hoprnet#8408).

Reads a gvpn-bench.sh run directory and answers three questions:

  1. WHICH ARM IS BETTER AT THE BOTTOM?   p10, floor rate, tail spread -- not the mean.
     The issue is about eliminating performance floors, not raising the ceiling, so an
     arm that is slightly slower on average with a quarter of the floor rate wins.

  2. WHERE DOES THE VARIANCE LIVE?        between-session vs within-session.
     A session is a fixed set of channels, an exit and a SURB warm-up; a rep inside it
     is a fresh draw over paths. If throughput varies a lot BETWEEN sessions but each
     session is internally stable, the problem is what a session gets assigned. If it
     varies a lot WITHIN a session, the problem is the per-packet path draw or
     transient relay load. Different diagnoses, different fixes.

  3. IS IT THE PATH OR THE CONGESTION CONTROLLER?   three measurements with no
     congestion controller in the loop: the client's own frame-discard telemetry,
     the ping running through the tunnel during the transfer (loss and mdev jitter,
     under load, no far end required), and -- when a server was available -- an
     iperf3 UDP leg. Loss on those alongside low TCP throughput is loss-driven CC
     collapse, which points at the session reassembly window rather than at relay
     capacity. The first two need nothing but the VM.

Also reported: frame discard rate from the client's own telemetry, and how many
candidate paths the planner drew from, per draw (needs planner DEBUG logging).

THE OUTPUT IS A DOCUMENT, NOT A DUMP. It opens with a verdict in words and three
numbers, and only then shows the tables that support it. Anyone should be able to
read the first fifteen lines and know the answer; the rest is there for whoever
wants to argue with it. `--markdown` writes the same thing as a file that can be
pasted into the issue unedited.

Comparisons carry 90% bootstrap confidence intervals. A p10 over a few dozen
sessions is one order statistic and moves around a lot, so without an interval
there is no way to tell a real change in the floor from one unlucky session.

Usage:  python3 gvpn-analyze.py RUN_DIR [--floor-mbps 5] [--markdown report.md]
                                        [--csv rows.csv] [--no-diagnostics]
"""

import argparse
import csv
import datetime as dt
import json
import random
import re
import statistics as st
import sys
import textwrap
from pathlib import Path

FLOOR_MBPS_DEFAULT = 2.0
SLOW_START_DROP_S = 5
MIN_SAMPLES = 3


# ----------------------------------------------------------------- helpers --

def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * (p / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def fmt(x, nd=2):
    return "-" if x is None else f"{x:.{nd}f}"


def med(xs):
    return st.median(xs) if xs else None


def cv(xs):
    """Coefficient of variation -- a spread measure comparable across different means."""
    xs = [x for x in xs if x is not None]
    if len(xs) < 2:
        return None
    m = st.mean(xs)
    return (st.pstdev(xs) / m) if m > 0 else None


# -------------------------------------------------------------- extraction --

def load_iperf(path: Path):
    """(1-second Mbit/s samples, total bytes, total seconds) from an iperf3 --json file."""
    try:
        data = json.loads(path.read_text())
    except Exception:
        return [], None, None
    iv = []
    for interval in data.get("intervals", []):
        s = interval.get("sum") or {}
        bps = s.get("bits_per_second")
        if bps is not None:
            iv.append(bps / 1e6)
    end = data.get("end") or {}
    tot = end.get("sum_received") or end.get("sum_sent") or end.get("sum") or {}
    return iv, tot.get("bytes"), tot.get("seconds")


def load_udp(path: Path):
    """(jitter_ms, loss_percent, Mbit/s) from an iperf3 UDP result."""
    try:
        data = json.loads(path.read_text())
    except Exception:
        return None, None, None
    end = data.get("end") or {}
    s = end.get("sum") or end.get("sum_received") or {}
    bps = s.get("bits_per_second")
    return s.get("jitter_ms"), s.get("lost_percent"), (bps / 1e6 if bps else None)


_PROM_LINE = re.compile(r'^(?P<name>[a-zA-Z_:][\w:]*)(?P<labels>\{[^}]*\})?\s+(?P<value>[0-9.eE+-]+)\s*$')
DISCARD = "hopr_session_frame_discarded_total"
COMPLETE = "hopr_session_frame_completed_total"
RETX = "hopr_session_ack_outgoing_retransmission_requests_total"
WANTED = {DISCARD, COMPLETE, RETX}


def telemetry_totals(path: Path):
    """
    Final value of each counter of interest, summed across label sets. The file is a
    concatenation of '# SAMPLE <ts>' scrapes, so the last one carries the run totals
    for monotonic counters.
    """
    if not path.exists():
        return {}
    totals, current = {}, {}
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("# SAMPLE") or line.startswith("# MARK"):
            if line.startswith("# SAMPLE") and current:
                totals = current
                current = {}
            continue
        if line.startswith("#"):
            continue
        m = _PROM_LINE.match(line.strip())
        if not m or m.group("name") not in WANTED:
            continue
        try:
            current[m.group("name")] = current.get(m.group("name"), 0.0) + float(m.group("value"))
        except ValueError:
            pass
    return current or totals


# `ping` prints its statistics block only when it is stopped with SIGINT, which is
# why gvpn-bench.sh signals it that way. These two lines are the whole payload:
# loss under load, and mdev as a jitter measure -- both with no congestion
# controller anywhere in the path, and no far end to arrange.
_PING_LOSS = re.compile(
    r'(\d+) packets transmitted,\s*(\d+)\s*(?:packets )?received.*?([\d.]+)% packet loss',
    re.S)
_PING_RTT = re.compile(
    r'(?:rtt|round-trip) min/avg/max/(?:mdev|stddev)\s*=\s*'
    r'([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)')


def load_ping(path):
    """(loss_percent, jitter_ms, rtt_avg_ms, sent) from a ping.txt summary."""
    if not path.exists():
        return None, None, None, None
    txt = path.read_text(errors="ignore")
    loss = sent = None
    m = _PING_LOSS.search(txt)
    if m:
        sent, loss = int(m.group(1)), float(m.group(3))
    jitter = rtt = None
    m = _PING_RTT.search(txt)
    if m:
        rtt, jitter = float(m.group(2)), float(m.group(4))
    return loss, jitter, rtt, sent


sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import routes  # noqa: E402  -- the one route parser, shared with use-arm.sh


def distinct_relays(path: Path):
    """The largest candidate set the planner drew from this session -- the pin
    check -- or None if it logged nothing (the column reads '-', not a misleading
    0). Not distinct paths over the session: a pinned planner still switches path
    at a cache refresh. See lib/routes.py."""
    if not path.exists():
        return None
    r = routes.scan(path.read_text(errors="ignore"))
    return r["candidates"] if r["lines"] else None


# ---------------------------------------------------------------- per rep --

def steady(iv, nbytes, secs):
    """The 1-second samples after TCP slow start, and whether the transfer was
    SHORT -- over before enough samples were left. A short transfer is scored by
    its whole-transfer rate rather than dropped: dropping it would discard exactly
    the fastest sessions and bias the comparison against the faster arm."""
    rest = iv[SLOW_START_DROP_S:]
    if len(rest) >= MIN_SAMPLES:
        return rest, False
    if nbytes and secs:
        return [nbytes * 8 / secs / 1e6], True
    return (iv[-1:] if iv else []), True


def analyse_rep(rd: Path):
    down_iv, dbytes, dsecs = load_iperf(rd / "iperf-down.json")
    down, short = steady(down_iv, dbytes, dsecs)
    up_iv, ubytes, usecs = load_iperf(rd / "iperf-up.json")
    up, _ = steady(up_iv, ubytes, usecs)
    jitter, uloss, umbps = load_udp(rd / "iperf-udp.json")
    timed_out = (rd / "iperf-down.timeout").exists() or (rd / "iperf-up.timeout").exists()

    if not down:
        return {"rep_dir": str(rd), "usable": False, "timed_out": timed_out}

    m = st.median(down)
    enough = len(down) >= MIN_SAMPLES
    p10, p90 = (pct(down, 10), pct(down, 90)) if enough else (None, None)
    return {
        "rep_dir": str(rd),
        "usable": True,
        "short": short,
        "timed_out": timed_out,
        "down_median": m,
        "down_p10": p10,
        "down_p90": p90,
        "tail_spread": (p90 / p10) if (p10 and p10 > 0) else None,
        "stall_rate": (sum(1 for v in down if v < 0.1 * m) / len(down)) if (m > 0 and not short) else None,
        "down_seconds": dsecs,
        "down_bytes": dbytes,
        "up_median": st.median(up) if up else None,
        "udp_jitter_ms": jitter,
        "udp_loss_pct": uloss,
        "udp_mbps": umbps,
        "samples": len(down),
    }


def analyse_session(sdir: Path):
    rep_dirs = sorted(sdir.glob("rep-*"), key=lambda p: int(p.name.split("-")[1]))
    if not rep_dirs:
        rep_dirs = [sdir]  # tolerate a run from an older bench version

    reps = [analyse_rep(rd) for rd in rep_dirs]
    usable = [r for r in reps if r.get("usable")]
    if not usable:
        return None

    meds = [r["down_median"] for r in usable]
    tel = telemetry_totals(sdir / "telemetry.prom")
    disc, comp = tel.get(DISCARD), tel.get(COMPLETE)
    ping_loss, ping_jitter, ping_rtt, ping_sent = load_ping(sdir / "ping.txt")

    return {
        "dir": str(sdir),
        "reps": reps,
        "n_reps": len(usable),
        "timed_out_reps": sum(1 for r in reps if r.get("timed_out")),
        "short_reps": sum(1 for r in usable if r.get("short")),
        "down_median": st.median(meds),          # the session's throughput
        "within_cv": cv(meds),                   # stability across its own reps
        "rep_medians": meds,
        "up_median": med([r["up_median"] for r in usable if r.get("up_median") is not None]),
        "tail_spread": med([r["tail_spread"] for r in usable if r["tail_spread"] is not None]),
        "stall_rate": med([r["stall_rate"] for r in usable if r["stall_rate"] is not None]),
        "down_seconds": med([r["down_seconds"] for r in usable if r.get("down_seconds")]),
        "udp_jitter_ms": med([r["udp_jitter_ms"] for r in usable if r.get("udp_jitter_ms") is not None]),
        "udp_loss_pct": med([r["udp_loss_pct"] for r in usable if r.get("udp_loss_pct") is not None]),
        "ping_loss_pct": ping_loss,
        "ping_jitter_ms": ping_jitter,
        "ping_rtt_ms": ping_rtt,
        "ping_sent": ping_sent,
        "discard_rate": (disc / (disc + comp)) if (disc is not None and comp is not None and (disc + comp) > 0) else None,
        "retx": tel.get(RETX),
        "relays": distinct_relays(sdir / "gnosisvpn.log"),
    }


# ----------------------------------------------------------------- layout --
#
# Everything below is presentation. One Table class renders both the console and
# the markdown export, so the two can never drift apart -- a report that says
# something different from the terminal it came from is worse than no report.

class Table:
    """Fixed-width console table that can also emit itself as GitHub markdown."""

    def __init__(self, cols, indent=2):
        # cols: list of (title, align) where align is "<" (text) or ">" (number)
        self.cols = cols
        self.indent = indent
        self.rows = []
        self.rules = set()          # row indices to precede with a light rule

    def row(self, *cells):
        self.rows.append([("-" if c is None else str(c)) for c in cells])
        return self

    def divider(self):
        self.rules.add(len(self.rows))
        return self

    def _widths(self):
        w = [len(t) for t, _ in self.cols]
        for r in self.rows:
            for i, c in enumerate(r):
                if i < len(w):
                    w[i] = max(w[i], len(c))
        return w

    def render(self):
        w = self._widths()
        pad = " " * self.indent
        gap = "  "
        def line(cells):
            return gap.join(f"{cells[j]:{self.cols[j][1]}{w[j]}}"
                            for j in range(len(self.cols))).rstrip()

        head = line([t for t, _ in self.cols])
        body = [(i, line([r[j] if j < len(r) else "" for j in range(len(self.cols))]))
                for i, r in enumerate(self.rows)]
        width = max([len(head)] + [len(b) for _, b in body])
        out = [pad + head, pad + "─" * width]
        for i, b in body:
            if i in self.rules:
                out.append(pad + "·" * width)
            out.append(pad + b)
        return out

    def markdown(self):
        out = ["| " + " | ".join(t for t, _ in self.cols) + " |",
               "|" + "|".join("---" if a == "<" else "--:" for _, a in self.cols) + "|"]
        for r in self.rows:
            out.append("| " + " | ".join(
                (r[j] if j < len(r) else "") for j in range(len(self.cols))) + " |")
        return out


def banner(title, sub=None, width=78):
    out = ["", "═" * width, "  " + title]
    if sub:
        out.append("  " + sub)
    out += ["═" * width, ""]
    return out


def section(n, title, note=None, width=78):
    out = ["", f"  {n}  {title}", "  " + "─" * (width - 2)]
    if note:
        out += ["     " + l for l in textwrap.wrap(note, width - 6)]
    out.append("")
    return out


def kv(label, value, lw=26):
    """One aligned line of the verdict block, so the arrows form a column."""
    return f"            {label:<{lw}}{value}"


def human_dur(seconds):
    if seconds is None or seconds < 0:
        return None
    h, m = divmod(int(seconds) // 60, 60)
    return f"{h} h {m:02d} m" if h else f"{m} m"


def signed_pct(x, nd=0):
    return "-" if x is None else f"{x:+.{nd}f}%"


# ------------------------------------------------------------- statistics --

def boot_rel_ci(base, arm, statfn, n=2000, conf=90, seed=8408):
    """Percentile-bootstrap CI for statfn(arm) vs statfn(base), as a percentage.

    The point estimate of a p10 is a single order statistic over a few dozen
    sessions, so it moves around a lot. Without an interval a reader cannot tell
    a real floor improvement from one unlucky session in the baseline -- and
    that distinction is the entire finding this issue is asking for.
    """
    base = [x for x in base if x is not None]
    arm = [x for x in arm if x is not None]
    if len(base) < 8 or len(arm) < 8:
        return None
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        b = statfn([base[rnd.randrange(len(base))] for _ in base])
        a = statfn([arm[rnd.randrange(len(arm))] for _ in arm])
        if b:
            out.append((a / b - 1.0) * 100.0)
    if len(out) < n // 2:
        return None
    out.sort()
    tail = (100 - conf) / 200.0
    return (out[int(len(out) * tail)], out[min(len(out) - 1, int(len(out) * (1 - tail)))])


def ci_str(ci, point):
    if point is None:
        return "-"
    if ci is None:
        return f"{point:+.0f}%"
    return f"{point:+.0f}%  ({ci[0]:+.0f} … {ci[1]:+.0f})"


def ci_verdict(ci):
    """-1 worse, 0 indistinguishable, +1 better, None unknown."""
    if ci is None:
        return None
    if ci[0] > 0:
        return 1
    if ci[1] < 0:
        return -1
    return 0


# ----------------------------------------------------------------- report --

def arm_stats(sessions, floor_mbps):
    meds = [s["down_median"] for s in sessions]
    ups = [s["up_median"] for s in sessions if s.get("up_median") is not None]
    p10, p50, p90 = pct(meds, 10), pct(meds, 50), pct(meds, 90)
    return {
        "n": len(sessions),
        "meds": meds,
        "p10": p10, "p50": p50, "p90": p90,
        "up": med(ups),
        "floor": sum(1 for m in meds if m < floor_mbps) / len(meds) * 100 if meds else None,
        "spread": (p90 / p10) if (p10 and p90) else None,
        "secs": med([s["down_seconds"] for s in sessions if s.get("down_seconds")]),
        "rtt": med([s["ping_rtt_ms"] for s in sessions if s.get("ping_rtt_ms") is not None]),
        "jit": med([s["ping_jitter_ms"] for s in sessions if s.get("ping_jitter_ms") is not None]),
        "loss": med([s["ping_loss_pct"] for s in sessions if s.get("ping_loss_pct") is not None]),
        "disc": med([s["discard_rate"] for s in sessions if s.get("discard_rate") is not None]),
        "relays": med([s["relays"] for s in sessions if s.get("relays") is not None]),
    }


def main():
    ap = argparse.ArgumentParser(
        description="Summarise a gvpn-bench.sh run into a report for hoprnet#8408.")
    ap.add_argument("run_dir")
    # Default None, resolved below against the manifest. "Below the floor" only
    # means something against a threshold chosen BEFORE anyone saw the pinned
    # arm; letting it default at analysis time is how the headline number becomes
    # whatever the analyst wanted.
    ap.add_argument("--floor-mbps", type=float, default=None,
                    help="a session median below this counts as a performance floor; "
                         "defaults to the value the study recorded in the manifest")
    ap.add_argument("--baseline", default="auto", help="arm to compare everything against")
    ap.add_argument("--csv", help="write per-session rows here")
    ap.add_argument("--markdown", help="write a complete issue-ready report here")
    ap.add_argument("--no-diagnostics", action="store_true",
                    help="headline and per-exit only; skip the supporting evidence")
    # The floor threshold has to be chosen BEFORE the study runs, from a
    # calibration run of the baseline arm alone. This prints that one number and
    # nothing else, so preflight can write it into the study file -- reusing the
    # same session parsing the report uses, rather than a second implementation
    # that could disagree with it.
    ap.add_argument("--emit-floor", action="store_true",
                    help="print the baseline arm's p25 session median and exit; "
                         "for calibrating GVPN_FLOOR_MBPS before a study")
    args = ap.parse_args()

    run = Path(args.run_dir)
    if not (run / "summary.csv").exists():
        sys.exit(f"no summary.csv in {run}")

    manifest = {}
    if (run / "manifest.json").exists():
        try:
            manifest = json.loads((run / "manifest.json").read_text())
        except Exception:
            pass
    finished = {}
    if (run / "finished.json").exists():
        try:
            finished = json.loads((run / "finished.json").read_text())
        except Exception:
            pass
    mode = manifest.get("mode", "time")
    BASE = args.baseline

    # Floor threshold: what the study declared, unless explicitly overridden here.
    recorded_floor = None
    try:
        recorded_floor = float(manifest.get("floor_mbps") or "")
    except (TypeError, ValueError):
        pass
    floor_note = None
    if args.floor_mbps is None:
        args.floor_mbps = recorded_floor if recorded_floor else FLOOR_MBPS_DEFAULT
        if not recorded_floor:
            floor_note = (f"No floor threshold was recorded for this run; using the "
                          f"default {FLOOR_MBPS_DEFAULT:g} Mbit/s. Set GVPN_FLOOR_MBPS in "
                          f"the study file so the threshold is fixed before the run.")
    elif recorded_floor and abs(recorded_floor - args.floor_mbps) > 1e-9:
        floor_note = (f"Floor threshold overridden on the command line "
                      f"({args.floor_mbps:g}); the study recorded {recorded_floor:g}. "
                      f"Say which one a quoted 'below' figure used.")

    by_arm, rows = {}, []

    def bucket(a):
        return by_arm.setdefault(a, {"sessions": [], "failed": 0})

    with (run / "summary.csv").open() as fh:
        for rec in csv.DictReader(fh):
            arm = rec["arm"]
            if rec.get("result") != "ok":
                bucket(arm)["failed"] += 1
                continue
            s = analyse_session(Path(rec["session_dir"]))
            if s is None:
                bucket(arm)["failed"] += 1
                continue
            s["arm"], s["cycle"] = arm, rec["cycle"]
            s["dest"] = rec.get("destination") or "-"
            bucket(arm)["sessions"].append(s)
            rows.append(s)

    if args.emit_floor:
        base = by_arm.get(BASE, {}).get("sessions", [])
        meds = [x["down_median"] for x in base if x.get("down_median")]
        if len(meds) < 3:
            sys.exit(f"only {len(meds)} usable '{BASE}' sessions; need >=3 to "
                     f"calibrate a floor. Run more calibration cycles.")
        print(f"{pct(meds, 25):.2f}")
        return

    if not rows:
        sys.exit("no usable sessions in this run")

    if args.csv:
        flat = [{k: v for k, v in r.items() if k not in ("reps", "rep_medians")} for r in rows]
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=sorted({k for r in flat for k in r}))
            w.writeheader()
            w.writerows(flat)

    stats = {a: arm_stats(g["sessions"], args.floor_mbps)
             for a, g in by_arm.items() if g["sessions"]}
    arms_sorted = ([BASE] if BASE in stats else []) + sorted(a for a in stats if a != BASE)
    exits = sorted({s.get("dest", "-") for s in rows})
    per_exit_delta = []          # (exit, rtt_ms, champion p10 delta %)

    # ---------------------------------------------------------- the verdict --

    base_meds = stats[BASE]["meds"] if BASE in stats else None
    champion, ci10, ci50, d10, d50 = None, None, None, None, None

    if base_meds:
        cands = [a for a in stats if a != BASE]
        if cands:
            champion = max(cands, key=lambda a: ((stats[a]["p10"] or 0),
                                                 -(stats[a]["floor"] or 100)))
            cm = stats[champion]["meds"]
            p10f = lambda xs: pct(xs, 10)
            p50f = lambda xs: pct(xs, 50)
            if stats[BASE]["p10"]:
                d10 = (stats[champion]["p10"] / stats[BASE]["p10"] - 1) * 100
            if stats[BASE]["p50"]:
                d50 = (stats[champion]["p50"] / stats[BASE]["p50"] - 1) * 100
            ci10 = boot_rel_ci(base_meds, cm, p10f)
            ci50 = boot_rel_ci(base_meds, cm, p50f)

    v10 = ci_verdict(ci10)
    floor_base = stats[BASE]["floor"] if BASE in stats else None
    floor_champ = stats[champion]["floor"] if champion else None

    # The pin not taking is not a result with a caveat, it is the absence of a
    # result: both arms ran the same routing. That has to outrank every other
    # verdict, or someone reads a table comparing an arm with itself.
    #
    # Checked on the arms CONFIGURED to pin (recorded by the bench from their
    # configs), not on whichever arm performed best: a winning unpinned arm
    # such as no-explore is supposed to draw from many candidates. Runs from
    # before the manifest field fall back to the arm names.
    declared = manifest.get("pinned_arms")
    pinned = (declared.split() if isinstance(declared, str) else
              [a for a in stats if a == "pin-planner" or a.startswith("pin-cfg-pinned")])
    broken_pins = [a for a in pinned if a in stats and stats[a]["relays"] is not None
                   and stats[a]["relays"] > 1.5]
    pin_broken = bool(broken_pins)

    # A trial is a rehearsal of the pipeline, not a measurement of anything: one
    # cycle of 5 MB transfers. It outranks every other verdict because the whole
    # failure mode this guards against is a rehearsal's report being pasted
    # somewhere as if it were the study.
    is_trial = bool(manifest.get("trial"))

    if is_trial:
        headline = ("TRIAL RUN — a rehearsal of the pipeline, not a result. "
                    "One cycle of small transfers; the numbers below say only "
                    "that every arm ran through.")
    elif champion is None:
        headline = f"Only one arm in this run — nothing to compare against '{BASE}'."
    elif pin_broken:
        a = broken_pins[0]
        headline = (f"THE PIN DID NOT TAKE — '{a}' still drew from "
                    f"{stats[a]['relays']:.1f} candidate paths. This run compares "
                    f"'{BASE}' with itself; the numbers below mean nothing.")
    elif v10 is None:
        headline = ("Too few sessions to separate the arms. "
                    "Treat this as a signal check, not a result.")
    elif v10 > 0 and floor_champ is not None and floor_champ < floor_base:
        headline = f"'{champion}' RAISES the performance floor vs '{BASE}'."
    elif v10 > 0:
        headline = (f"'{champion}' lifts the slow tail, but the share of floored "
                    f"sessions is not clearly lower.")
    elif v10 < 0:
        headline = f"'{champion}' makes the slow tail WORSE vs '{BASE}'."
    elif d10 is not None and abs(d10) > 15:
        # A large point estimate with an interval that still includes zero is the
        # easiest result in this whole exercise to over-claim. Say both halves.
        headline = (f"Suggestive but NOT conclusive: '{champion}' measures "
                    f"{d10:+.0f}% on the slow tail, but the interval still includes "
                    f"no change. Needs more sessions before it can be reported.")
    else:
        headline = ("No measurable difference in the slow tail. "
                    "Path diversity is not what produces the floors.")

    W = 78
    out = []
    out += banner("hoprnet#8408 — pinned path vs. automatic path finding",
                  "download throughput unless stated otherwise; Mbit/s", W)
    for i, line in enumerate(textwrap.wrap(headline, W - 14)):
        out.append(("  VERDICT   " if i == 0 else "            ") + line)
    out.append("")

    if champion:
        b, c = stats[BASE], stats[champion]
        out.append(kv("", f"{BASE:>12}  →  {champion:<14}"))

        def arrow(lo, hi, nd=2, suffix=""):
            return f"{fmt(lo, nd) + suffix:>12}  →  {fmt(hi, nd) + suffix:<14}"

        out.append(kv("slowest 10% of sessions",
                      arrow(b["p10"], c["p10"]) + ci_str(ci10, d10)))
        if floor_base is not None:
            out.append(kv(f"sessions below {args.floor_mbps:g} Mbit/s",
                          f"{floor_base:>11.0f}%  →  {f'{floor_champ:.0f}%':<14}"
                          f"{floor_champ - floor_base:+.0f} points"))
        out.append(kv("typical session (median)",
                      arrow(b["p50"], c["p50"]) + ci_str(ci50, d50)))
        out.append(kv("spread p90/p10", arrow(b["spread"], c["spread"], 1, "x")))
        out.append("")
        out.append("            Ranges are 90% bootstrap confidence intervals. One that spans 0")
        out.append("            means the arms are indistinguishable at this sample size.")
        out.append("")

    # provenance
    start = manifest.get("started") or ""
    dur = None
    if start and finished.get("finished"):
        try:
            t0 = dt.datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ")
            t1 = dt.datetime.strptime(finished["finished"], "%Y-%m-%dT%H:%M:%SZ")
            dur = human_dur((t1 - t0).total_seconds())
        except Exception:
            pass
    bits = []
    if manifest.get("study"):
        bits.append(f"study {manifest['study']}")
    if manifest.get("kit_rev"):
        bits.append(f"kit {manifest['kit_rev']}")
    bits.append(f"{len(rows)} sessions")
    if dur:
        bits.append(dur)
    n_ex = len([e for e in exits if e != "-"]) or 1
    bits.append(f"{n_ex} exit" + ("s" if n_ex > 1 else ""))
    ver = manifest.get("client_package") or manifest.get("client_service")
    if ver:
        bits.append(f"client {ver}")
    if manifest.get("network"):
        bits.append(manifest["network"])
    out.append("  RUN       " + " · ".join(bits))
    load = (f"{manifest.get('dl_bytes')} bytes" if mode == "bytes"
            else f"{manifest.get('dl_seconds')}s")
    out.append(f"            {load} per transfer × {manifest.get('reps','?')} rep(s), "
               f"{manifest.get('rep_gap_s','?')}s apart · started {start or '?'}")
    if finished.get("exit") not in (None, 0):
        out.append(f"            WARNING: the run exited non-zero ({finished['exit']}) — "
                   f"it may have been cut short.")
    out.append("")

    # ------------------------------------------------------- 1. headline --

    out += section(1, "THROUGHPUT BY ARM",
                   "The floor is the point of the exercise: read 'slow 10%' and "
                   "'below' first, then check what the median cost was to get there.", W)

    t = Table([("arm", "<"), ("sessions", ">"), ("fail", ">"),
               ("slow 10%", ">"), ("median", ">"), ("fast 10%", ">"),
               ("upload", ">"), (f"below {args.floor_mbps:g}", ">"), ("p90/p10", ">"),
               (f"Δ slow 10% vs {BASE}", ">")])
    for a in arms_sorted:
        s = stats[a]
        delta = "—"
        if a != BASE and base_meds and s["p10"] and stats[BASE]["p10"]:
            dd = (s["p10"] / stats[BASE]["p10"] - 1) * 100
            delta = ci_str(boot_rel_ci(base_meds, s["meds"], lambda xs: pct(xs, 10)), dd)
        t.row(a, s["n"], by_arm[a]["failed"],
              fmt(s["p10"]), fmt(s["p50"]), fmt(s["p90"]), fmt(s["up"]),
              f"{s['floor']:.0f}%" if s["floor"] is not None else "-",
              f"{fmt(s['spread'],1)}x" if s["spread"] else "-",
              delta)
    for a in sorted(by_arm):
        if a not in stats:
            t.row(a, 0, by_arm[a]["failed"], "-", "-", "-", "-", "-", "-", "—")
    out += t.render()
    headline_table = t
    out.append("")
    out.append("     slow 10% / fast 10%  the 10th and 90th percentile of the per-session")
    out.append("                          median: a bad session, and a good session")
    out.append(f"     below {args.floor_mbps:<15g}share of sessions whose median never reached it —")
    out.append("                          the number this issue wants driven down")
    out.append("     p90/p10              how far apart good and bad sessions are; 1.0x")
    out.append("                          would mean every session performs alike")

    # ---------------------------------------------------- 2. per exit node --

    real_exits = [e for e in exits if e != "-"]
    if real_exits:
        out += section(2, "BY EXIT NODE",
                       "Same comparison, split by exit. Each row is one arm against "
                       "one exit.", W)
        te = Table([("exit", "<"), ("arm", "<"), ("n", ">"),
                    ("slow 10%", ">"), ("median", ">"), ("fast 10%", ">"), ("upload", ">"),
                    (f"below {args.floor_mbps:g}", ">"), ("rtt ms", ">"), ("jitter ms", ">"),
                    ("loss %", ">"), ("discard %", ">"), ("candidates", ">"),
                    (f"Δ median vs {BASE}", ">")])
        first = True
        for ex in real_exits:
            if not first:
                te.divider()
            first = False
            ex_rows = [(a, [s for s in by_arm[a]["sessions"] if s.get("dest") == ex])
                       for a in arms_sorted]
            ex_rows = [(a, ss) for a, ss in ex_rows if ss]
            ebase = None
            for a, ss in ex_rows:
                if a == BASE:
                    ebase = arm_stats(ss, args.floor_mbps)
            champ_delta = None
            for a, ss in ex_rows:
                s = arm_stats(ss, args.floor_mbps)
                d = "—"
                if a != BASE and ebase and ebase["p50"] and s["p50"]:
                    dv = (s["p50"] / ebase["p50"] - 1) * 100
                    d = f"{dv:+.0f}%"
                    if a == champion:
                        champ_delta = dv
                te.row(ex if a == ex_rows[0][0] else "", a, s["n"],
                       fmt(s["p10"]), fmt(s["p50"]), fmt(s["p90"]), fmt(s["up"]),
                       f"{s['floor']:.0f}%" if s["floor"] is not None else "-",
                       fmt(s["rtt"], 0), fmt(s["jit"], 1), fmt(s["loss"], 2),
                       fmt(s["disc"] * 100, 2) if s["disc"] is not None else "-",
                       fmt(s["relays"], 1), d)
            if ebase:
                per_exit_delta.append((ex, ebase["rtt"], champ_delta))
        out += te.render()
        exit_table = te

        pts = [(r, d) for _, r, d in per_exit_delta if r is not None and d is not None]
        trend = None
        if len(pts) >= 2:
            pts.sort()
            (rlo, dlo), (rhi, dhi) = pts[0], pts[-1]
            if dhi - dlo > 5:
                trend = (f"The pinning benefit GROWS with path RTT "
                         f"({rlo:.0f} ms → {dlo:+.0f}%, {rhi:.0f} ms → {dhi:+.0f}%). "
                         f"That is what a reassembly-window limit predicts: the further "
                         f"the exit, the more reordering a striped transfer accumulates "
                         f"inside a window sized for a LAN.")
            elif dlo - dhi > 5:
                trend = (f"The pinning benefit SHRINKS with path RTT "
                         f"({rlo:.0f} ms → {dlo:+.0f}%, {rhi:.0f} ms → {dhi:+.0f}%), "
                         f"which is the opposite of the reassembly-window prediction — "
                         f"look at relay load instead.")
            else:
                trend = ("The benefit does not track path RTT, so whatever causes the "
                         "floors is not obviously distance-dependent.")
        if trend:
            out.append("")
            for line in textwrap.wrap(trend, W - 5):
                out.append("     " + line)

    # ------------------------------------------------------ 3. diagnostics --

    if not args.no_diagnostics:
        out += section(3, "SUPPORTING EVIDENCE",
                       "Why the arms differ. None of this is the headline; it is what "
                       "lets you argue for a fix rather than just report a gap.", W)

        # 3a path quality
        out.append("  3a  Path quality — measured with NO congestion controller in the loop,")
        out.append("      so it separates 'the path loses packets' from 'TCP overreacts'.")
        out.append("")
        tq = Table([("arm", "<"), ("frame discard %", ">"), ("TCP retx", ">"),
                    ("ping loss %", ">"), ("ping jitter ms", ">"), ("ping rtt ms", ">"),
                    ("UDP loss %", ">"), ("UDP jitter ms", ">"), ("candidate paths", ">")])
        for a in arms_sorted:
            ss = by_arm[a]["sessions"]

            def c(key, scale=1.0, nd=2):
                vals = [s[key] for s in ss if s.get(key) is not None]
                return fmt(med(vals) * scale, nd) if vals else "-"
            tq.row(a, c("discard_rate", 100, 2), c("retx", 1, 0),
                   c("ping_loss_pct", 1, 2), c("ping_jitter_ms", 1, 1),
                   c("ping_rtt_ms", 1, 1), c("udp_loss_pct", 1, 2),
                   c("udp_jitter_ms", 1, 1), c("relays", 1, 1))
        out += tq.render()
        quality_table = tq
        out.append("")
        out.append("      frame discard %   frames that arrived but missed the reassembly")
        out.append("                        window. High here + low ping loss = the path is")
        out.append("                        fine and the window is the bottleneck.")
        out.append("      ping loss/jitter  from a ping running THROUGH the tunnel during the")
        out.append("                        transfer. Needs no far end, and measures under load.")
        out.append("      distinct routes   how many routes the planner drew from. The pinned")
        out.append("                        arm must read 1.0 — if it does not, the pin never")
        out.append("                        took and every number above is about nothing.")

        # pin sanity check, stated loudly
        if champion and stats[champion]["relays"] and stats[champion]["relays"] > 1.5:
            out.append("")
            out.append(f"      *** '{champion}' drew from {stats[champion]['relays']:.1f} routes, "
                       f"not 1. The pin did not take.")
            out.append("          Treat this whole report as void until use-arm.sh --count reads 1.")

        # 3b variance
        if any(s["within_cv"] is not None for g in by_arm.values() for s in g["sessions"]):
            out.append("")
            out.append("  3b  Where the variance lives — is a session dealt its fate, or does it")
            out.append("      flicker while you hold it open? Different causes, different fixes.")
            out.append("")
            tv = Table([("arm", "<"), ("between sessions", ">"), ("within a session", ">"),
                        ("reading", "<")])
            for a in arms_sorted:
                ss = by_arm[a]["sessions"]
                if len(ss) < 2:
                    continue
                between = cv([s["down_median"] for s in ss])
                within = med([s["within_cv"] for s in ss if s["within_cv"] is not None])
                verdict = "-"
                if between is not None and within is not None:
                    if within > 1.5 * between:
                        verdict = "flickers inside a session"
                    elif between > 1.5 * within:
                        verdict = "the session is dealt its fate"
                    else:
                        verdict = "both, comparably"
                tv.row(a, fmt(between, 3), fmt(within, 3), verdict)
            out += tv.render()
            out.append("")
            out.append("      Coefficient of variation; lower is steadier.")
            out.append("      dealt its fate  → what a session GETS (channels, exit, SURB warm-up)")
            out.append("                        decides it. Look at which relays it had channels to.")
            out.append("      flickers        → the per-packet draw or transient relay load. Look")
            out.append("                        at frame discards and the route count.")

        # 3c rep trend
        max_reps = max((len(s["rep_medians"]) for g in by_arm.values()
                        for s in g["sessions"]), default=0)
        if max_reps > 1:
            out.append("")
            out.append("  3c  Does a held-open session decay? Median Mbit/s of each transfer,")
            out.append(f"      {manifest.get('rep_gap_s','?')}s apart, within one connection.")
            out.append("")
            tr = Table([("arm", "<")] + [(f"rep {i+1}", ">") for i in range(max_reps)])
            for a in arms_sorted:
                ss = by_arm[a]["sessions"]
                cells = []
                for i in range(max_reps):
                    vals = [s["rep_medians"][i] for s in ss if len(s["rep_medians"]) > i]
                    cells.append(fmt(med(vals)))
                tr.row(a, *cells)
            out += tr.render()
            out.append("")
            out.append("      flat    a session's throughput is a property of the session")
            out.append("      falling it degrades while held open (SURB or channel drift)")
            out.append("      noisy   each transfer re-draws its luck — the striping prediction")

        # 3d paired
        if BASE in by_arm:
            base_by_cycle = {}
            for s in by_arm[BASE]["sessions"]:
                base_by_cycle[(s["cycle"], s.get("dest"))] = s["down_median"]
            pair_rows = []
            for a in arms_sorted:
                if a == BASE:
                    continue
                d = [s["down_median"] - base_by_cycle[(s["cycle"], s.get("dest"))]
                     for s in by_arm[a]["sessions"]
                     if (s["cycle"], s.get("dest")) in base_by_cycle]
                if d:
                    pair_rows.append((a, len(d), st.median(d),
                                      sum(1 for x in d if x > 0) / len(d) * 100))
            if pair_rows:
                out.append("")
                out.append(f"  3d  Head to head against '{BASE}' within the same cycle, so network-wide")
                out.append("      load variation cancels out.")
                out.append("")
                tp = Table([("arm", "<"), ("paired cycles", ">"),
                            ("median Δ Mbit/s", ">"), (f"beat {BASE}", ">")])
                for a, n, dm, winpct in pair_rows:
                    tp.row(a, n, f"{dm:+.2f}", f"{winpct:.0f}% of cycles")
                out += tp.render()
                out.append("")
                out.append("      An arm that gives up a little median while cutting the 'below'")
                out.append("      column is the outcome this issue asks for — say so explicitly")
                out.append("      rather than letting a lower median read as a regression.")

    # ------------------------------------------------------------ caveats --

    n_min = min((s["n"] for s in stats.values()), default=0)
    caveats = []
    if floor_note:
        caveats.append(floor_note)
    if is_trial:
        caveats.append("This was a --trial run: 1 cycle, 1 rep, 5 MB transfers. "
                       "It proves the arms load and data moves. It cannot "
                       "support any comparison between arms — re-run without "
                       "--trial for that.")
    for a in broken_pins:
        caveats.append(f"'{a}' drew from {stats[a]['relays']:.1f} candidate paths, not 1. "
                       f"Its [connection.path_planner] override is not applied — check "
                       f"`use-arm.sh --show`, then re-run `use-arm.sh {a} --count` until "
                       f"it reads candidates=1.")
    if BASE in stats and stats[BASE]["relays"] is not None and stats[BASE]["relays"] <= 1:
        caveats.append(f"'{BASE}' drew from a single candidate path: the baseline had no "
                       f"path diversity to lose, so no arm can be compared against it. "
                       f"Check the node's open channels.")
    if n_min < 30:
        caveats.append(f"Smallest arm has {n_min} usable sessions. Tail statistics are not "
                       f"trustworthy below ~30 — signal check, not a result.")
    n_short = sum(r.get("short_reps", 0) for r in rows)
    if n_short and not is_trial:
        caveats.append(f"{n_short} transfer(s) finished within the {SLOW_START_DROP_S} s "
                       f"slow-start window; each is scored by its whole-transfer rate "
                       f"and has no tail or stall figures. Many of these means the "
                       f"transfers are too small for this link — raise GVPN_DL_BYTES in the study.")
    tot_fail = sum(g["failed"] for g in by_arm.values())
    if tot_fail > len(rows) * 0.1:
        caveats.append(f"{tot_fail} sessions failed or produced no data "
                       f"({tot_fail / (len(rows) + tot_fail) * 100:.0f}% of attempts). "
                       f"Failures are not random — check whether one arm failed more.")
    if champion and stats[champion]["relays"] is None:
        caveats.append("No route counts: planner DEBUG logging was off, so nothing here "
                       "confirms the pin actually took.")
    if caveats:
        out.append("")
        out.append("  ⚠ CAVEATS")
        for cvt in caveats:
            for i, line in enumerate(textwrap.wrap(cvt, W - 6, break_on_hyphens=False)):
                out.append("    " + ("• " if i == 0 else "  ") + line)
    out.append("")

    print("\n".join(l.rstrip() for l in out))

    # ---------------------------------------------- markdown for the issue --

    if args.markdown:
        m = []
        m.append("## Bandwidth: pinned path vs. automatic path finding")
        m.append("")
        m.append(f"**{headline}**")
        m.append("")
        # Limits go above the numbers, not in a footer: a reader who stops after
        # the first table must have already seen what the numbers cannot support.
        if caveats:
            m.append("> [!WARNING]")
            for i, cvt in enumerate(caveats):
                if i:
                    m.append(">")
                m.append(f"> {cvt}")
            m.append("")
        if champion:
            m.append(f"| | `{BASE}` | `{champion}` | change |")
            m.append("|---|--:|--:|--:|")
            m.append(f"| slowest 10% of sessions | {fmt(stats[BASE]['p10'])} | "
                     f"{fmt(stats[champion]['p10'])} | {ci_str(ci10, d10)} |")
            if floor_base is not None:
                m.append(f"| sessions below {args.floor_mbps:g} Mbit/s | {floor_base:.0f}% | "
                         f"{floor_champ:.0f}% | {floor_champ - floor_base:+.0f} points |")
            m.append(f"| typical session (median) | {fmt(stats[BASE]['p50'])} | "
                     f"{fmt(stats[champion]['p50'])} | {ci_str(ci50, d50)} |")
            m.append(f"| spread p90/p10 | {fmt(stats[BASE]['spread'],1)}x | "
                     f"{fmt(stats[champion]['spread'],1)}x | |")
            m.append("")
            m.append("Parenthesised ranges are 90% bootstrap confidence intervals; one that "
                     "spans 0 means the arms are indistinguishable at this sample size.")
            m.append("")
        m.append(f"Run: {' · '.join(bits)}. "
                 f"{load} per transfer × {manifest.get('reps','?')} rep(s), "
                 f"{manifest.get('rep_gap_s','?')}s apart. Started {start or '?'}.")
        m.append("")
        m.append("### Throughput by arm (Mbit/s)")
        m.append("")
        m += headline_table.markdown()
        m.append("")
        if real_exits:
            m.append("### By exit node")
            m.append("")
            m += exit_table.markdown()
            m.append("")
            if trend:
                m.append(trend)
                m.append("")
        if not args.no_diagnostics:
            m.append("### Why they differ")
            m.append("")
            m.append("None of these involve a congestion controller, so they separate "
                     "\"the path loses packets\" from \"TCP overreacts to loss\".")
            m.append("")
            m += quality_table.markdown()
            m.append("")
        m.append("<details><summary>How to read the columns</summary>")
        m.append("")
        m.append("- **slow 10% / fast 10%** — 10th/90th percentile of the per-session median: "
                 "a bad session and a good session.")
        m.append(f"- **below {args.floor_mbps:g}** — share of sessions whose median never reached "
                 f"{args.floor_mbps:g} Mbit/s. This is the number the issue asks to drive down.")
        m.append("- **p90/p10** — how far apart good and bad sessions are. 1.0x would mean "
                 "every session performs alike.")
        m.append("- **frame discard %** — frames that arrived but missed the session "
                 "reassembly window. High here with low ping loss means the path is fine and "
                 "the window is the bottleneck.")
        m.append("- **ping loss / jitter** — from a ping running *through* the tunnel during "
                 "the transfer, so it is measured under load and needs no second machine.")
        m.append("- **distinct routes** — how many routes the planner drew from. The pinned "
                 "arm must read 1.0, otherwise the pin never took.")
        m.append("")
        m.append("</details>")
        m.append("")
        Path(args.markdown).write_text("\n".join(m))
        print(f"  Issue-ready report written to {args.markdown}\n")


if __name__ == "__main__":
    main()
