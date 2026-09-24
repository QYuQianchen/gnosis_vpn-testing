#!/usr/bin/env python3
"""Build and check gnosis_vpn config.toml files for benchmark arms.

    tomlmerge.py render BASE OVERLAY OUT --hops N [--destination NAME] [--label TEXT]
    tomlmerge.py check  FILE
    tomlmerge.py get    FILE dotted.key         prints the value, or nothing if unset

render  copies BASE, keeps only --destination (if given), sets
        `path = { hops = N }` on each destination, and MERGES OVERLAY table by
        table: a table BASE already has gets the overlay's keys set inside it;
        a new table is appended. The result is parsed and checked to carry
        every overlay value before it is written -- nothing invalid is written.

check   exits non-zero if FILE does not parse or declares a table twice.

Why merge, not append: the packaged network configs already contain
[connection.path_planner]. A second one is a TOML error ("cannot declare
table twice"); gnosis_vpn-root maps every config error to exit 66 and the
service will not start.

Text-level on purpose: the stdlib parses TOML but cannot write it, and a
third-party writer would reformat the operator's file. The parser judges the
result afterwards.
"""
import argparse
import re
import sys

try:
    import tomllib                          # Python >= 3.11
except ModuleNotFoundError:                 # pragma: no cover
    try:
        import tomli as tomllib             # apt install python3-tomli
    except ModuleNotFoundError:
        tomllib = None

HEADER = re.compile(r'^\s*\[(?!\[)\s*(.+?)\s*\]\s*(#.*)?$')     # [table], not [[array]]
KEYLINE = re.compile(r'^\s*([A-Za-z0-9_-]+|"[^"]*"|\'[^\']*\')\s*=')
STRINGS = re.compile(r'"(?:\\.|[^"\\])*"|\'[^\']*\'')


def die(msg):
    sys.exit(f"tomlmerge: {msg}")


def split_key(dotted):
    """'destinations."UK".path' -> ('destinations', 'UK', 'path')."""
    return tuple(a or b or c for a, b, c in
                 re.findall(r'"([^"]*)"|\'([^\']*)\'|([A-Za-z0-9_-]+)', dotted))


def sections(text):
    """[(key, lines)] in file order; key None is the preamble before any table."""
    out = [(None, [])]
    for ln in text.splitlines():
        m = HEADER.match(ln)
        if m:
            out.append((split_key(m.group(1)), [ln]))
        else:
            out[-1][1].append(ln)
    return out


def span(lines, i):
    """Number of lines the assignment at lines[i] occupies (multi-line arrays)."""
    depth = 0
    for n, ln in enumerate(lines[i:], 1):
        s = STRINGS.sub('""', ln).split('#', 1)[0]
        if n == 1:
            s = s.split('=', 1)[1]
        depth += s.count('[') + s.count('{') - s.count(']') - s.count('}')
        if depth <= 0:
            return n
    return len(lines) - i


def assignments(lines):
    """[(key, [lines])] for every key assignment in a section body."""
    out, i = [], 1
    while i < len(lines):
        m = KEYLINE.match(lines[i])
        if m:
            n = span(lines, i)
            out.append((m.group(1).strip('"\''), lines[i:i + n]))
            i += n
        else:
            i += 1
    return out


def set_key(lines, key, new):
    """Replace key's assignment in a section, or add it before trailing blanks."""
    i = 1
    while i < len(lines):
        m = KEYLINE.match(lines[i])
        if m and m.group(1).strip('"\'') == key:
            lines[i:i + span(lines, i)] = new
            return
        i += 1
    end = len(lines)
    while end > 1 and not lines[end - 1].strip():
        end -= 1
    lines[end:end] = new


def duplicates(text):
    seen, dups = set(), []
    for key, _ in sections(text)[1:]:
        if key in seen and key not in dups:
            dups.append(key)
        seen.add(key)
    return dups


def parse(text, what):
    dups = duplicates(text)
    if dups:
        die(f"{what}: table declared twice: " +
            ", ".join('[' + '.'.join(d) + ']' for d in dups))
    if tomllib is None:
        print(f"tomlmerge: WARNING: no TOML parser (install python3-tomli); "
              f"{what} checked for duplicate tables only", file=sys.stderr)
        return None
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        die(f"{what} does not parse: {e}")


def lookup(tree, path):
    for p in path:
        if not isinstance(tree, dict) or p not in tree:
            return KeyError
        tree = tree[p]
    return tree


def render(a):
    base_text = open(a.base).read()
    parse(base_text, f"base config {a.base}")
    over_text = open(a.overlay).read() if a.overlay else ""
    over = parse(over_text, f"overlay {a.overlay}") if a.overlay else {}
    over_secs = sections(over_text)
    if any(KEYLINE.match(ln) for ln in over_secs[0][1]):
        die(f"overlay {a.overlay}: top-level keys are not supported; put them under a table")

    secs = sections(base_text)
    dests = [k[1] for k, _ in secs[1:] if k and len(k) == 2 and k[0] == 'destinations']
    if a.destination and a.destination not in dests:
        die(f"destination {a.destination!r} not in {a.base}; it has: {', '.join(dests)}")
    keep = {a.destination} if a.destination else set(dests)

    out = []
    for key, lines in secs:
        if key and key[0] == 'destinations' and len(key) >= 2:
            if key[1] not in keep:
                continue                                    # other exits
            if len(key) >= 3 and key[2] == 'path':
                continue                                    # replaced below
            if len(key) == 2:
                set_key(lines, 'path', [f'path = {{ hops = {a.hops} }}'])
        out.append((key, lines))

    for key, lines in over_secs[1:]:
        target = next((l for k, l in out if k == key), None)
        if target is None:
            out.append((key, lines))                        # new table
        else:
            for k, new in assignments(lines):               # existing table
                set_key(target, k, [ln.strip() for ln in new])

    banner = [f"# GENERATED by gvpn-8408 lib/tomlmerge.py -- {a.label or 'arm'}",
              f"# base: {a.base}  hops: {a.hops}  -- re-render, do not edit", ""]
    text = "\n".join(banner + [ln for _, lines in out for ln in lines]).rstrip() + "\n"

    result = parse(text, "rendered config")
    if result is not None:                                  # prove the merge
        for key, _ in over_secs[1:]:
            tbl = lookup(over, key)
            for k, v in (tbl.items() if isinstance(tbl, dict) else []):
                if not isinstance(v, dict) and lookup(result, key + (k,)) != v:
                    die(f"merge check failed: [{'.'.join(key)}] {k} = "
                        f"{lookup(result, key + (k,))!r}, arm wants {v!r}")
        for d in keep:
            if lookup(result, ('destinations', d, 'path', 'hops')) != int(a.hops):
                die(f"merge check failed: destinations.{d}.path.hops != {a.hops}")
    open(a.out, "w").write(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render")
    r.add_argument("base")
    r.add_argument("overlay", help="config fragment, or - for none")
    r.add_argument("out")
    r.add_argument("--hops", required=True)
    r.add_argument("--destination")
    r.add_argument("--label")
    c = sub.add_parser("check")
    c.add_argument("file")
    g = sub.add_parser("get")
    g.add_argument("file"); g.add_argument("key")
    a = ap.parse_args()
    if a.cmd == "get":
        v = lookup(parse(open(a.file).read(), a.file) or {}, tuple(a.key.split(".")))
        if v is not KeyError:
            print(v)
        return
    if a.cmd == "render":
        a.overlay = None if a.overlay == "-" else a.overlay
        render(a)
    else:
        parse(open(a.file).read(), a.file)
        print(f"ok: {a.file}")


if __name__ == "__main__":
    main()
