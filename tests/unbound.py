#!/usr/bin/env python3
"""Find variables a script uses WITHOUT a default and never assigns.

    unbound.py SCRIPT...     exit 1 and list them if any

Under `set -u`, such a reference aborts the script -- the failure that shipped
when the faucet-code variables were deleted but two uses of them were not. Only
unguarded uses count: `$X`, `${X}`, `${X#..}`; not `${X:-..}`, `${X-..}`,
`${X:+..}`, `${X:=..}`. A name counts as assigned if the script, lib/common.sh
or gvpn.conf assigns it anywhere (NAME=, local/declare/export/readonly NAME,
read ... NAME, for NAME in, printf -v NAME, getopts .. NAME).

Deliberately simple and conservative: it reads text, not an AST, so it strips
comments, single-quoted strings, escaped `\\$` and heredoc bodies with a quoted
delimiter (which the shell does not expand) before looking.
"""
import pathlib
import re
import sys

KIT = pathlib.Path(__file__).resolve().parent.parent
SHARED = [KIT / "lib" / "common.sh", KIT / "gvpn.conf"]
BUILTIN = {
    "HOME", "PATH", "PWD", "USER", "SHELL", "TERM", "IFS", "SUDO_USER", "EUID", "UID",
    "BASH_SOURCE", "BASH_REMATCH", "LINENO", "FUNCNAME", "RANDOM", "SECONDS",
    "OPTARG", "OPTIND", "PPID", "BASHPID", "REPLY", "PIPESTATUS", "HOSTNAME", "TMPDIR",
}
USE = re.compile(r'\$(?:\{(#?)([A-Za-z_][A-Za-z0-9_]*)([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))')
GUARD = re.compile(r'^(\[[^]]*\])?:?[-+=?]')
ASSIGN = [
    re.compile(r'(?:^|[\s;&|(`])(?:local|declare|export|readonly|typeset)(?:\s+-\w+)*\s+([^;&|)]*)'),
    re.compile(r'(?:^|[\s;&|(`{])([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]]*\])?\+?='),
    # read: options that take an argument (-a -d -i -n -N -p -t -u) consume the
    # next word; flag options (-r -s -e) do not -- they must not eat the name.
    re.compile(r'\bread\b(?:\s+-[rse]+|\s+-[adinNptu]\s+\S+)*\s+((?:[A-Za-z_][A-Za-z0-9_]*\s*)+)'),
    re.compile(r'\beval\s+["\']?([A-Za-z_][A-Za-z0-9_]*)='),
    re.compile(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b'),
    re.compile(r'\bprintf\s+-v\s+([A-Za-z_][A-Za-z0-9_]*)'),
    re.compile(r'\bgetopts\s+\S+\s+([A-Za-z_][A-Za-z0-9_]*)'),
]


def strip(text):
    """Remove what the shell never expands: comments, '...' and quoted heredocs."""
    out, lines, i = [], text.splitlines(), 0
    while i < len(lines):
        ln = lines[i]
        m = re.search(r"<<-?\s*(['\"])(\w+)\1", ln)
        if m:                                         # quoted heredoc: blank its body
            out.append(ln[:m.start()])                # (blank, not drop: keep line numbers)
            end = m.group(2); i += 1
            while i < len(lines) and lines[i].strip() != end:
                out.append(""); i += 1
            out.append(""); i += 1
            continue
        ln = ln.replace("\\$", "")                  # \$X is literal text, not a use
        ln = re.sub(r"'[^']*'", "''", ln)
        ln = re.sub(r'(^|\s)#.*$', r'\1', ln)
        out.append(ln); i += 1
    return "\n".join(out)


def assigned(text):
    names = set()
    for rx in ASSIGN:
        for m in rx.finditer(text):
            for g in m.groups():
                if g:
                    names.update(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)(?:=|\s|$)', g + ' '))
    names.update(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\(\)', text, re.M))  # not vars, harmless
    return names


def unguarded(text):
    uses = {}
    for n, ln in enumerate(text.splitlines(), 1):
        for m in USE.finditer(ln):
            name = m.group(2) or m.group(4)
            rest = m.group(3) or ""
            if m.group(2) and GUARD.match(rest):
                continue
            uses.setdefault(name, n)
    return uses


def main():
    shared = set()
    for f in SHARED:
        if f.exists():
            shared |= assigned(strip(f.read_text()))
    bad = 0
    for path in sys.argv[1:]:
        text = strip(pathlib.Path(path).read_text())
        known = shared | assigned(text) | BUILTIN
        for name, line in sorted(unguarded(text).items(), key=lambda kv: kv[1]):
            if name not in known:
                print(f"  {path}:{line}: ${name} is used without a default and never assigned")
                bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
