#!/usr/bin/env python3
"""
Static check for install.sh: catches the class of bug where a printf format
string has a different number of %-specifiers than arguments.

When bash printf is given MORE arguments than specifiers it silently RECYCLES
the format string, so the surplus argument gets printed a second time. That is
almost never intended, so flag any mismatch.

Usage:  python3 check_printf.py install.sh
"""
import re
import sys

SPEC = re.compile(r"%[-+ #0-9.*]*[sdq]")


def logical_commands(lines):
    """Join backslash-continued lines into single logical commands."""
    out, buf, start = [], "", 0
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if not buf:
            start = i
        buf = (buf + " " + stripped) if buf else stripped
        if buf.rstrip().endswith("\\"):
            buf = buf.rstrip()[:-1]
            continue
        out.append((start, buf))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


def split_top_level(text):
    """Split into (kind, value) tokens, honouring quotes and $( )."""
    toks, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t":
            i += 1
            continue
        if c == "\\":
            i += 2
            continue
        if c in "'\"":
            quote, j, buf = c, i + 1, []
            while j < n:
                if text[j] == "\\" and quote == '"':
                    buf.append(text[j : j + 2])
                    j += 2
                    continue
                if text[j] == quote:
                    break
                buf.append(text[j])
                j += 1
            toks.append(("word", "".join(buf)))
            i = j + 1
            continue
        if c == "|":
            toks.append(("word", "|"))
            i += 1
            continue
        j = i
        depth = 0
        while j < n:
            ch = text[j]
            if ch == "\\":
                j += 2
                continue
            if ch in "'\"":
                q, j = ch, j + 1
                while j < n and text[j] != q:
                    j += 2 if (q == '"' and text[j] == "\\") else 1
                j += 1
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "|" and depth == 0:
                break
            j += 1
        toks.append(("word", text[i:j]))
        i = j
    return toks


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "install.sh"
    src = open(path, encoding="utf-8").read()
    # drop heredoc bodies: their content is data, not commands
    lines, out, i = src.split("\n"), [], 0
    heredoc = None
    for line in lines:
        s = line.strip()
        if heredoc is not None:
            if s == heredoc:
                heredoc = None
            out.append("")
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if m:
            heredoc = m.group(1)
        out.append(line)

    problems = 0
    for start, cmd in logical_commands(out):
        if not re.match(r"printf\b", cmd):
            continue
        # cut the command at a top-level pipe / redirect / && - the args we
        # care about are only the ones belonging to this printf
        toks = split_top_level(cmd[len("printf") :].strip())
        words = []
        for kind, val in toks:
            if val in ("|", "&&", "||", ";"):
                break
            if val.startswith(">") or val.startswith("<"):
                break
            words.append(val)
        if len(words) < 2:
            continue
        fmt = words[0]
        nspec = len(SPEC.findall(fmt))
        nargs = len(words) - 1
        if nargs != nspec:
            problems += 1
            print(f"line {start}: {nspec} specifier(s), {nargs} arg(s)  "
                  f"[{'EXTRA -> format will be recycled' if nargs > nspec else 'MISSING -> will print empty'}]")
            print(f"    {cmd[:160]}")
    if problems == 0:
        print("printf arg/format counts: all balanced")
    else:
        print(f"\n{problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
