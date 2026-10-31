#!/usr/bin/env python3
"""No check of the self-test may stop quietly.

    python3 scripts/check_selftest_skips.py [Sources/PrivacyBrowser/App/SelfTest.swift]

Fails (exit 1) on every `guard … else { … }` or `else { … }` block of the self-test that, after an
`info(…)` line and without a `check(…)` or a `skip(…)`, leaves its function with `return` (or
`continue`/`break` in a loop of checks), or stands in for the checks of the `if` block beside it:
that is a check that degenerated on this machine and said so only in a note no summary counts (owner, 1 November: "Молчаливое вырождение запрещено"). Such a block
must call `skip(name, reason, place)`, which prints a SKIP line, counts it and names it again in
the summary. Blocks that return a value to a helper's caller (`return nil`, `return false`, …) are
not checks and are left alone.
"""
import re
import sys

DEFAULT = "Sources/PrivacyBrowser/App/SelfTest.swift"


def blank(source):
    """The source with string literals and comments blanked out (line breaks kept), so that
    braces and words inside them are not read as code."""
    out, i, n = [], 0, len(source)
    stack, mode, depth = [], "code", 0
    while i < n:
        c = source[i]
        if mode == "code":
            if source.startswith("//", i):
                j = source.find("\n", i)
                j = n if j < 0 else j
                out.append(" " * (j - i))
                i = j
                continue
            if source.startswith("/*", i):
                j = source.find("*/", i)
                j = n if j < 0 else j + 2
                out.append("".join("\n" if ch == "\n" else " " for ch in source[i:j]))
                i = j
                continue
            if source.startswith('"""', i):
                j = source.find('"""', i + 3)
                j = n if j < 0 else j + 3
                out.append('"' + "".join("\n" if ch == "\n" else "_" for ch in source[i + 1:j - 1]) + '"')
                i = j
                continue
            if c == '"':
                mode = "string"
                out.append('"')
                i += 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if stack and depth == stack[-1]:
                    stack.pop()
                    mode = "string"
                    out.append("_")
                    i += 1
                    continue
                depth -= 1
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n and source[i + 1] == "(":
            stack.append(depth)
            mode = "code"
            out.append("__")
            i += 2
            continue
        if c == "\\":
            out.append("__")
            i += 2
            continue
        if c == '"':
            mode = "code"
            out.append('"')
            i += 1
            continue
        out.append("\n" if c == "\n" else "_")
        i += 1
    return "".join(out)


def closing(code, start):
    """The index of the brace that closes the one at `start`."""
    depth, i = 0, start
    while i < len(code):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(code)


def opening(code, end):
    """The index of the brace that opens the one that closes at `end`."""
    depth, i = 0, end
    while i >= 0:
        if code[i] == "}":
            depth += 1
        elif code[i] == "{":
            depth -= 1
            if depth == 0:
                return i
        i -= 1
    return 0


def blocks(code):
    """(line, body, the body of the `if` block before it or None) of every `guard … else { … }`
    and `else { … }` block."""
    for match in re.finditer(r"\belse\s*\{", code):
        start = match.end() - 1
        body = code[start + 1:closing(code, start)]
        before = code[:match.start()].rstrip()
        sibling = None
        if before.endswith("}"):
            end = len(before) - 1
            sibling = code[opening(code, end) + 1:end]
        yield code.count("\n", 0, match.start()) + 1, body, sibling


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    source = open(path, encoding="utf-8").read()
    code = blank(source)
    lines = source.split("\n")
    quiet = []
    reports = re.compile(r"(?<![\w.])(check|skip)\(")
    for line, body, sibling in blocks(code):
        if not re.search(r"(?<![\w.])info\(", body):
            continue
        if reports.search(body) or re.search(r"\bthrow\b", body):
            continue
        # Leaves the checks after it, or stands in for the checks of the `if` block beside it.
        leaves = re.search(r"\b(return|continue|break)\s*(\}|$|\n)", body)
        instead = sibling is not None and reports.search(sibling)
        if not leaves and not instead:
            continue
        quiet.append((line, lines[line - 1].strip()[:160]))
    for line, text in quiet:
        print(f"{path}:{line}: a check stops after an info line without skip() or check(): {text}")
    if quiet:
        print(f"::error::the self-test has {len(quiet)} block(s) that stop a check quietly: call skip(name, reason, place)")
        return 1
    print(f"{path}: no check stops quietly (every block that leaves after a note calls skip() or check())")
    return 0


if __name__ == "__main__":
    sys.exit(main())
