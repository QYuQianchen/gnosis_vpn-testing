#!/usr/bin/env python3
# Fabricated bench runs for tests/run-analyze-tests.sh -- see that script for why.
"""Fabricate a gvpn-bench run directory so the report layout can be exercised."""
import json, random, sys
from pathlib import Path

def iperf(samples, secs, byts):
    return json.dumps({
        "intervals": [{"sum": {"bits_per_second": v * 1e6}} for v in samples],
        "end": {"sum_received": {"bytes": byts, "seconds": secs}}})

def make(root, scenario):
    rnd = random.Random(7)
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    (root / "manifest.json").write_text(json.dumps({
        "version": "0.4.0", "profile": "soak", "mode": "bytes",
        "dl_bytes": "26214400", "reps": 3, "rep_gap_s": 300,
        "client_service": "0.96.2", "client_package": "2026.09.17+build.134506",
        "channel": "stable", "network": "jura-prod", "kit_rev": "a1b2c3d",
        "arms": "auto pin-planner no-explore", "started": "2026-09-19T08:00:00Z"}))
    (root / "finished.json").write_text(json.dumps(
        {"finished": "2026-09-21T01:12:00Z", "exit": 0}))

    exits = scenario["exits"]
    arms = scenario["arms"]
    lines = ["cycle,arm,destination,session_dir,connect_seconds,reps,result"]

    for cyc in range(1, scenario["cycles"] + 1):
        for ex, exrtt in exits.items():
            for arm, prof in arms.items():
                sd = root / f"cycle-{cyc:03d}" / f"{arm}__{ex}"
                sd.mkdir(parents=True, exist_ok=True)
                base = prof["mbps"] * scenario["exit_scale"].get(ex, 1.0)
                # a fraction of sessions land on the floor
                floored = rnd.random() < prof["floor_p"]
                lvl = rnd.uniform(0.6, 1.9) * base * (0.12 if floored else 1.0)
                for rep in range(1, 4):
                    rd = sd / f"rep-{rep}"; rd.mkdir(exist_ok=True)
                    jit = prof["within"]
                    sm = [max(0.05, rnd.gauss(lvl, lvl * jit)) for _ in range(30)]
                    (rd / "iperf-down.json").write_text(
                        iperf(sm, 26214400 * 8 / (lvl * 1e6), 26214400))
                    (rd / "iperf-up.json").write_text(
                        iperf([max(0.05, rnd.gauss(lvl * 0.45, lvl * 0.45 * jit))
                               for _ in range(30)], 20, 10485760))
                rtt = exrtt + rnd.gauss(0, 8)
                (sd / "ping.txt").write_text(
                    f"--- 1.1.1.1 ping statistics ---\n"
                    f"400 packets transmitted, {400 - int(prof['loss']*4)} received, "
                    f"{prof['loss']:.2f}% packet loss, time 100s\n"
                    f"rtt min/avg/max/mdev = {rtt*0.8:.1f}/{rtt:.1f}/"
                    f"{rtt*2:.1f}/{prof['jit']:.1f} ms\n")
                comp = 100000
                disc = int(comp * prof["disc"] * (1 + exrtt / 200))
                (sd / "telemetry.prom").write_text(
                    f"# SAMPLE 1\nhopr_session_frame_completed_total 10\n"
                    f"# SAMPLE 2\n"
                    f"hopr_session_frame_completed_total {comp}\n"
                    f"hopr_session_frame_discarded_total {disc}\n"
                    f"hopr_session_ack_outgoing_retransmission_requests_total {prof['retx']}\n")
                nroutes = prof["routes"]
                (sd / "gnosisvpn.log").write_text("\n".join(
                    f'candidate path path="{i}" w=1' for i in range(nroutes)))
                lines.append(f"{cyc},{arm},{ex},{sd},3.2,3,ok")
    (root / "summary.csv").write_text("\n".join(lines) + "\n")

SCEN = {
  "win": {
    "cycles": 14, "exits": {"UK": 90, "USA": 150, "India": 280},
    "exit_scale": {"UK": 1.0, "USA": 0.8, "India": 0.55},
    "arms": {
      "auto":        dict(mbps=18, floor_p=0.30, within=0.45, loss=1.8, jit=14.0, disc=0.021, retx=900, routes=12),
      "pin-planner": dict(mbps=17, floor_p=0.07, within=0.18, loss=1.6, jit=5.0,  disc=0.004, retx=260, routes=1),
      "no-explore":  dict(mbps=18, floor_p=0.18, within=0.32, loss=1.7, jit=9.0,  disc=0.012, retx=600, routes=6),
    }},
  "null": {
    "cycles": 12, "exits": {"UK": 90},
    "exit_scale": {},
    "arms": {
      "auto":        dict(mbps=18, floor_p=0.20, within=0.35, loss=1.8, jit=11.0, disc=0.015, retx=800, routes=11),
      "pin-planner": dict(mbps=18, floor_p=0.19, within=0.34, loss=1.8, jit=11.0, disc=0.014, retx=790, routes=1),
    }},
  # Five arms, five cycles: a real effect, too few sessions to see it. The
  # arm profiles are IDENTICAL to "win", so anything this scenario gets wrong
  # is sampling, not configuration -- which is the point being asserted.
  "thin": {
    "cycles": 5, "exits": {"UK": 90},
    "exit_scale": {},
    "arms": {
      "auto":        dict(mbps=18, floor_p=0.30, within=0.45, loss=1.8, jit=14.0, disc=0.021, retx=900, routes=12),
      "pin-planner": dict(mbps=17, floor_p=0.07, within=0.18, loss=1.6, jit=5.0,  disc=0.004, retx=260, routes=1),
      "no-explore":  dict(mbps=18, floor_p=0.18, within=0.32, loss=1.7, jit=9.0,  disc=0.012, retx=600, routes=6),
      "narrow":      dict(mbps=18, floor_p=0.12, within=0.25, loss=1.6, jit=7.0,  disc=0.008, retx=420, routes=3),
      "zero-hop":    dict(mbps=22, floor_p=0.03, within=0.12, loss=0.9, jit=3.0,  disc=0.001, retx=90,  routes=1),
    }},
  "broken": {
    "cycles": 6, "exits": {"UK": 90},
    "exit_scale": {},
    "arms": {
      "auto":        dict(mbps=18, floor_p=0.25, within=0.40, loss=1.8, jit=12.0, disc=0.018, retx=800, routes=11),
      "pin-planner": dict(mbps=18, floor_p=0.24, within=0.39, loss=1.8, jit=12.0, disc=0.018, retx=800, routes=9),
    }},
}

make(sys.argv[1], SCEN[sys.argv[2]])
print("built", sys.argv[1])
