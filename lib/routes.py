#!/usr/bin/env python3
"""Measure how many routes the path planner draws from, from its DEBUG lines.

    routes.py LOGFILE [--from-byte N]
    -> lines=12 rebuilds=4 candidates=3 forward=3 return=3 churn=9 destinations=1

Needs RUST_LOG with hopr_transport::path::planner=debug (00-vm-setup.sh).

What the planner logs (hopr-transport, transport/hopr/src/path/planner.rs):

  rebuild_candidates() logs one "weighted candidate path" line PER CANDIDATE,
  all together, each time a destination's cache entry is rebuilt -- kind="fill"
  (miss), "background-refresh" (periodic reweight) or "recompute". The lines of
  one rebuild carry sampling_probability values that sum to 1. Fields follow the
  message as name=value; `path` is the route's Display form and may contain
  spaces, so a value runs to the next ` name=`.

  The return-path draw logs "drawing return paths from tempered weights" with
  candidates=<n>.

Measures:
  candidates  THE PIN CHECK: the largest candidate set any draw chose from --
              max(forward, return). 1 means one path at a time: no striping.
  forward     the largest rebuild (lines grouped per destination until their
              probabilities reach 1, or a path repeats)
  return      the largest candidates= on a return-path draw
  churn       distinct paths per destination over the whole window. With one
              candidate this is > 1 whenever a refresh picked a different
              path -- one path at a time, not one path for the session.
"""
import re
import sys

ANSI = re.compile(r'\x1b\[[0-9;]*m')
FIELD = re.compile(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_.]*)=')


def fields(line):
    """name=value pairs after the message; a value runs to the next ` name=`."""
    ms = list(FIELD.finditer(line))
    out = {}
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(line)
        out[m.group(1)] = line[m.end():end].strip().strip('"')
    return out


def scan(text):
    lines, ret, sizes = 0, 0, []
    open_ = {}                          # destination -> [paths in this rebuild, prob sum]
    seen = {}                           # destination -> every path, for churn

    def close(dest):
        paths = open_.pop(dest, [[], 0.0])[0]
        if paths:
            sizes.append(len(paths))

    for raw in text.splitlines():
        ln = ANSI.sub('', raw)
        if 'drawing return paths from tempered weights' in ln:
            try:
                ret = max(ret, int(fields(ln).get('candidates', 0)))
            except ValueError:
                pass
            continue
        if 'weighted candidate path' not in ln:
            continue
        lines += 1
        f = fields(ln)
        dest, path = f.get('destination', '?'), f.get('path', '')
        seen.setdefault(dest, set()).add(path)
        g = open_.get(dest)
        if g and path in g[0]:          # a path cannot appear twice in one rebuild
            close(dest)
        g = open_.setdefault(dest, [[], 0.0])
        g[0].append(path)
        try:
            g[1] += float(f.get('sampling_probability', 'nan'))
        except ValueError:
            pass
        if g[1] >= 0.999:               # this rebuild's probabilities are complete
            close(dest)
    for dest in list(open_):
        close(dest)

    fwd = max(sizes, default=0)
    return {
        'lines': lines,
        'rebuilds': len(sizes),
        'candidates': max(fwd, ret),
        'forward': fwd,
        'return': ret,
        'churn': max((len(p) for p in seen.values()), default=0),
        'destinations': len(seen),
    }


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
    print(' '.join(f'{k}={v}' for k, v in scan(text).items()))


if __name__ == '__main__':
    main()
