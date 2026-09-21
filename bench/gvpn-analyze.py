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
distinct routes the planner actually drew from (needs planner DEBUG logging).

Usage:  python3 gvpn-analyze.py RUN_DIR [--floor-mbps 2.0] [--csv rows.csv]
"""

import argparse
import csv
import json
import re
import statistics as st
import sys
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
    return iv[SLOW_START_DROP_S:], tot.get("bytes"), tot.get("seconds")


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


_PATH_LINE = re.compile(r'\bpath="?(?P<path>[^",]+)"?')


def distinct_relays(path: Path):
    """
    Distinct routes named by the planner's DEBUG candidate lines. Needs
    RUST_LOG=...hopr_transport::path::planner=debug; returns None when the lines are
    absent, so the column reads '-' rather than a misleading 0.
    """
    if not path.exists():
        return None
    seen, saw_any = set(), False
    for line in path.read_text(errors="ignore").splitlines():
        if "candidate path" not in line:
            continue
        saw_any = True
        m = _PATH_LINE.search(line)
        if m:
            seen.add(m.group("path"))
    return len(seen) if saw_any else None


# ---------------------------------------------------------------- per rep --

def analyse_rep(rd: Path):
    down, dbytes, dsecs = load_iperf(rd / "iperf-down.json")
    up, _, _ = load_iperf(rd / "iperf-up.json")
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
        "timed_out": timed_out,
        "down_median": m,
        "down_p10": p10,
        "down_p90": p90,
        "tail_spread": (p90 / p10) if (p10 and p10 > 0) else None,
        "stall_rate": (sum(1 for v in down if v < 0.1 * m) / len(down)) if m > 0 else None,
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


# ----------------------------------------------------------------- report --

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--floor-mbps", type=float, default=FLOOR_MBPS_DEFAULT)
    ap.add_argument("--csv", help="write per-session rows here")
    ap.add_argument("--markdown", help="write a GitHub-ready comparison table here")
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
    mode = manifest.get("mode", "time")

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

    if args.csv and rows:
        flat = [{k: v for k, v in r.items() if k not in ("reps", "rep_medians")} for r in rows]
        with open(args.csv, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=sorted({k for r in flat for k in r}))
            w.writeheader()
            w.writerows(flat)

    # ---- headline table ----
    print()
    if mode == "bytes":
        print(f"Mode: bytes -- {manifest.get('dl_bytes','?')} per download, "
              f"{manifest.get('reps','?')} rep(s) per session, "
              f"{manifest.get('rep_gap_s','?')}s apart.")
        print("Headline: secs (completion time, lower better), p10, floor%.")
    else:
        print(f"Mode: time -- {manifest.get('dl_seconds','?')}s per download, "
              f"{manifest.get('reps','?')} rep(s) per session, "
              f"{manifest.get('rep_gap_s','?')}s apart.")
        print("Headline: p10, floor%, spread.")
    print(f"Throughput in Mbit/s. Floor threshold: {args.floor_mbps} Mbit/s session median.")
    print()

    hdr = (f"{'arm':<16}{'n':>4}{'fail':>5}{'to':>4}{'secs':>8}"
           f"{'p10':>8}{'p50':>8}{'p90':>8}{'floor%':>8}{'spread':>8}{'mean':>8}")
    print(hdr)
    print("-" * len(hdr))

    for arm in sorted(by_arm):
        g = by_arm[arm]
        ss = g["sessions"]
        if not ss:
            print(f"{arm:<16}{0:>4}{g['failed']:>5}" + "      -" * 11)
            continue
        meds = [s["down_median"] for s in ss]
        floor = sum(1 for m in meds if m < args.floor_mbps) / len(meds) * 100
        print(
            f"{arm:<16}{len(ss):>4}{g['failed']:>5}"
            f"{sum(s['timed_out_reps'] for s in ss):>4}"
            f"{fmt(med([s['down_seconds'] for s in ss if s['down_seconds']]), 1):>8}"
            f"{fmt(pct(meds, 10)):>8}{fmt(pct(meds, 50)):>8}{fmt(pct(meds, 90)):>8}"
            f"{fmt(floor, 1):>8}"
            f"{fmt(med([s['tail_spread'] for s in ss if s['tail_spread']]), 1):>8}"
            f"{fmt(st.mean(meds)):>8}"
        )

    # ---- path quality: everything measured with NO congestion controller in the
    # loop. This is what separates "the path is losing packets" from "TCP is
    # overreacting to loss" -- and it decides whether the fix is the reassembly
    # window or more relay capacity.
    def col(ss, key, scale=1.0, nd=2):
        vals = [s[key] for s in ss if s.get(key) is not None]
        return fmt(med(vals) * scale, nd) if vals else "-"

    print()
    print("Path quality -- no congestion control in any of these:")
    q = (f"  {'arm':<16}{'disc%':>8}{'retx':>8}{'ploss%':>8}{'pjit_ms':>9}"
         f"{'prtt_ms':>9}{'uloss%':>8}{'ujit_ms':>9}{'relays':>8}")
    print(q)
    print("  " + "-" * (len(q) - 2))
    for arm in sorted(by_arm):
        ss = by_arm[arm]["sessions"]
        if not ss:
            continue
        print(
            f"  {arm:<16}"
            f"{col(ss, 'discard_rate', 100, 2):>8}"
            f"{col(ss, 'retx', 1, 0):>8}"
            f"{col(ss, 'ping_loss_pct', 1, 2):>8}"
            f"{col(ss, 'ping_jitter_ms', 1, 1):>9}"
            f"{col(ss, 'ping_rtt_ms', 1, 1):>9}"
            f"{col(ss, 'udp_loss_pct', 1, 2):>8}"
            f"{col(ss, 'udp_jitter_ms', 1, 1):>9}"
            f"{col(ss, 'relays', 1, 1):>8}"
        )
    print()
    print("  disc%   frames that arrived but missed the reassembly window (client telemetry)")
    print("  ploss%/pjit_ms  loss and mdev jitter from the ping running THROUGH the tunnel")
    print("                  during the transfer -- needs no far end, and measures under load")
    print("  uloss%/ujit_ms  iperf3 UDP, when a --udp-host was configured")
    print("  relays  distinct routes the planner drew from (needs planner DEBUG logging).")
    print("          pin-planner should read 1.0; if it does not, the pin did not take.")

    # ---- variance decomposition ----
    if any(s["within_cv"] is not None for g in by_arm.values() for s in g["sessions"]):
        print()
        print("Where the variance lives (coefficient of variation, lower = more stable):")
        print(f"  {'arm':<16}{'between-session':>17}{'within-session':>16}{'verdict':>28}")
        for arm in sorted(by_arm):
            ss = by_arm[arm]["sessions"]
            if len(ss) < 2:
                continue
            between = cv([s["down_median"] for s in ss])
            within = med([s["within_cv"] for s in ss if s["within_cv"] is not None])
            verdict = "-"
            if between is not None and within is not None:
                if within > 1.5 * between:
                    verdict = "flickers inside a session"
                elif between > 1.5 * within:
                    verdict = "session is assigned its fate"
                else:
                    verdict = "both, comparably"
            print(f"  {arm:<16}{fmt(between, 3):>17}{fmt(within, 3):>16}{verdict:>28}")
        print()
        print("  between >> within  -> what a session GETS (its channels, exit, SURB warm-up)")
        print("                        decides its throughput; it then stays there. Look at")
        print("                        which relays that session had channels to.")
        print("  within >> between  -> throughput moves under a fixed session: the per-packet")
        print("                        path draw or transient relay load. Look at frame")
        print("                        discards and the distinct-relay count.")

    # ---- rep trend: does a held-open session decay or recover? ----
    max_reps = max((len(s["rep_medians"]) for g in by_arm.values() for s in g["sessions"]), default=0)
    if max_reps > 1:
        print()
        print("Throughput by repeat within a held-open session (median Mbit/s):")
        print(f"  {'arm':<16}" + "".join(f"{'rep' + str(i + 1):>9}" for i in range(max_reps)))
        for arm in sorted(by_arm):
            ss = by_arm[arm]["sessions"]
            cells = ""
            for i in range(max_reps):
                vals = [s["rep_medians"][i] for s in ss if len(s["rep_medians"]) > i]
                cells += f"{fmt(med(vals)):>9}"
            print(f"  {arm:<16}{cells}")
        print()
        print("  A flat row means a session's throughput is a property of the session.")
        print("  A falling row means it degrades while held open (SURB or channel drift).")
        print("  A noisy row means each transfer re-draws its luck -- which is the")
        print("  multipath-striping prediction.")

    # ---- paired per-cycle comparison ----
    if "auto" in by_arm:
        base = {s["cycle"]: s["down_median"] for s in by_arm["auto"]["sessions"]}
        print()
        print("Paired per-cycle delta vs. 'auto' (both arms saw the same minute of load):")
        for arm in sorted(by_arm):
            if arm == "auto":
                continue
            d = [s["down_median"] - base[s["cycle"]]
                 for s in by_arm[arm]["sessions"] if s["cycle"] in base]
            if d:
                print(f"  {arm:<16} n={len(d):<4} median Δ = {st.median(d):+7.2f} Mbit/s   "
                      f"beats auto in {sum(1 for x in d if x > 0) / len(d) * 100:.0f}% of cycles")
        print()
        print("Read the deltas with floor% above: an arm that loses a little median")
        print("throughput while cutting floor% is the outcome this issue wants.")

    # ---- per exit: the comparison the issue actually asks for ----
    exits = sorted({s.get("dest", "-") for g in by_arm.values() for s in g["sessions"]})
    if len(exits) > 1 or (exits and exits[0] != "-"):
        print()
        print("Per exit node -- pinned vs auto, one block per exit.")
        print("Mbit/s; dn = download, up = upload; rtt/jit from the in-tunnel ping.")
        for ex in exits:
            rows = [(arm, [s for s in g["sessions"] if s.get("dest") == ex])
                    for arm, g in sorted(by_arm.items())]
            rows = [(a, ss) for a, ss in rows if ss]
            if not rows:
                continue
            print()
            print(f"  exit: {ex}")
            h = (f"    {'arm':<16}{'n':>4}{'dn_p10':>8}{'dn_p50':>8}{'dn_p90':>8}"
                 f"{'up_p50':>8}{'floor%':>8}{'rtt_ms':>8}{'jit_ms':>8}{'loss%':>7}{'disc%':>7}{'relays':>7}")
            print(h)
            print("    " + "-" * (len(h) - 4))
            base_med = None
            for arm, ss in rows:
                meds = [s["down_median"] for s in ss]
                if arm == "auto":
                    base_med = med(meds)
                print(
                    f"    {arm:<16}{len(ss):>4}"
                    f"{fmt(pct(meds,10)):>8}{fmt(pct(meds,50)):>8}{fmt(pct(meds,90)):>8}"
                    f"{fmt(med([s['up_median'] for s in ss if s.get('up_median') is not None])):>8}"
                    f"{fmt(sum(1 for m in meds if m < args.floor_mbps)/len(meds)*100,1):>8}"
                    f"{fmt(med([s['ping_rtt_ms'] for s in ss if s.get('ping_rtt_ms') is not None]),1):>8}"
                    f"{fmt(med([s['ping_jitter_ms'] for s in ss if s.get('ping_jitter_ms') is not None]),1):>8}"
                    f"{fmt(med([s['ping_loss_pct'] for s in ss if s.get('ping_loss_pct') is not None]),2):>7}"
                    f"{fmt((med([s['discard_rate'] for s in ss if s.get('discard_rate') is not None]) or 0)*100,2) if any(s.get('discard_rate') is not None for s in ss) else '-':>7}"
                    f"{fmt(med([s['relays'] for s in ss if s.get('relays') is not None]),1) if any(s.get('relays') is not None for s in ss) else '-':>7}"
                )
            if base_med:
                for arm, ss in rows:
                    if arm == "auto":
                        continue
                    m = med([s["down_median"] for s in ss])
                    if m:
                        print(f"    {arm} vs auto: {(m/base_med - 1)*100:+.1f}% download median")

    # ---- a table to paste into the issue ----
    if args.markdown:
        with open(args.markdown, "w") as fh:
            fh.write("| exit | arm | n | dn p10 | dn p50 | dn p90 | up p50 | floor% | rtt ms | jit ms | loss% | disc% | relays |\n")
            fh.write("|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|\n")
            for ex in exits:
                for arm, g in sorted(by_arm.items()):
                    ss = [s for s in g["sessions"] if s.get("dest") == ex]
                    if not ss:
                        continue
                    meds = [s["down_median"] for s in ss]
                    fh.write("| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n".format(
                        ex, arm, len(ss),
                        fmt(pct(meds,10)), fmt(pct(meds,50)), fmt(pct(meds,90)),
                        fmt(med([s['up_median'] for s in ss if s.get('up_median') is not None])),
                        fmt(sum(1 for m in meds if m < args.floor_mbps)/len(meds)*100,1),
                        fmt(med([s['ping_rtt_ms'] for s in ss if s.get('ping_rtt_ms') is not None]),1),
                        fmt(med([s['ping_jitter_ms'] for s in ss if s.get('ping_jitter_ms') is not None]),1),
                        fmt(med([s['ping_loss_pct'] for s in ss if s.get('ping_loss_pct') is not None]),2),
                        fmt((med([s['discard_rate'] for s in ss if s.get('discard_rate') is not None]) or 0)*100,2)
                            if any(s.get('discard_rate') is not None for s in ss) else "-",
                        fmt(med([s['relays'] for s in ss if s.get('relays') is not None]),1)
                            if any(s.get('relays') is not None for s in ss) else "-"))
        print()
        print(f"Markdown table for the issue written to {args.markdown}")

    n_min = min((len(g["sessions"]) for g in by_arm.values()), default=0)
    if n_min < 30:
        print()
        print(f"CAUTION: smallest arm has {n_min} usable sessions. Tail statistics are not")
        print("trustworthy below ~30 -- treat this as a signal check, not a result.")
    print()


if __name__ == "__main__":
    main()
