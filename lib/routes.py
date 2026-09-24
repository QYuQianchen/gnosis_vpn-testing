#!/usr/bin/env python3
"""Count the routes the path planner used, from its DEBUG log lines.

    routes.py LOGFILE [--from-byte N]      prints: lines=<n> paths=<n> candidates=<n>

Needs RUST_LOG with hopr_transport::path::planner=debug (00-vm-setup.sh). The
planner (hopr-transport, transport/hopr/src/path/planner.rs) emits, per query:

  "weighted candidate path"   ... hops=1 path=<route> cost=0.12 composite_weight=...
  "drawing return paths from tempered weights"  ... candidates=<n> distinct_relayers=<n>

`path` is the route's Display form and can contain spaces, so a value runs to
the next ` field=` -- not to the next space or comma. Getting that wrong folds
the per-line cost into the "route" and makes a pinned arm look unpinned.

Two independent measures, so a format surprise shows up as disagreement:
  paths       distinct route strings across "weighted candidate path" lines
  candidates  the largest candidate count the return-path draw reported
A working pin reads 1 on both.
"""
import re
import sys

ANSI = re.compile(r'\x1b\[[0-9;]*m')
PATH = re.compile(r'\bpath=(?P<v>.+?)(?=\s+[A-Za-z_][A-Za-z0-9_.]*=|\s*$)')
CANDS = re.compile(r'\bcandidates=(?P<n>\d+)')


def scan(text):
    lines, paths, cands = 0, set(), 0
    for ln in text.splitlines():
        ln = ANSI.sub('', ln)
        if 'weighted candidate path' in ln:
            lines += 1
            m = PATH.search(ln)
            if m:
                paths.add(m.group('v').strip().strip('"'))
        if 'drawing return paths from tempered weights' in ln:
            m = CANDS.search(ln)
            if m:
                cands = max(cands, int(m.group('n')))
    return {'lines': lines, 'paths': len(paths), 'candidates': cands}


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    start = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == '--from-byte' else 0
    try:
        with open(sys.argv[1], 'rb') as fh:
            fh.seek(start)
            text = fh.read().decode(errors='ignore')
    except FileNotFoundError:
        text = ''
    r = scan(text)
    print(' '.join(f'{k}={v}' for k, v in r.items()))


if __name__ == '__main__':
    main()
