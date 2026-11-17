#!/usr/bin/env python3
"""Where Safari's code in a profile's process looked for its stores, from an fs_usage trace.

    sudo fs_usage -w -f filesys LumenProfile > fs.txt &      # while scripts/address_bar_check.sh runs
    python3 -I scripts/safari_stores_trace.py fs.txt --real-home "$HOME"

Prints `STORES-TRACE` lines about the calls of the profiles' processes (LumenProfile):

  * what they looked for in the profile's home and did not find (ENOENT), by path, the home written
    as <home> — where Safari's frameworks expect a store or a folder that is not there;
  * what they were refused (EPERM, EACCES), anywhere — the sandbox's and the system's refusals: the
    real Safari's data present but closed to a profile shows as EPERM where a runner with no Safari
    data has ENOENT;
  * what they asked of the account's own ~/Library outside the vault, and what came of it;
  * the stores they opened in the home's Library/Safari.

A measurement: exit 0 whatever it finds; 1 when the trace holds nothing of the profiles' processes.
"""
import argparse
import re
import sys
from collections import Counter

FAILED = re.compile(r"^\S+\s+\S+\s+\[\s*(\d+)\](?!/)")
OPENS = {"open", "openat", "open_nocancel", "openat_nocancel", "open_extended", "creat", "open_dprotected_np"}
NAMES = {1: "EPERM", 2: "ENOENT", 13: "EACCES", 20: "ENOTDIR", 21: "EISDIR", 17: "EEXIST", 30: "EROFS", 63: "ENAMETOOLONG"}
HOME_MARK = "/home.noindex"


def parse(line):
    """(call, errno or None, path, process) of one line of the trace; None for a line without a
    whole path (one relative to a descriptor, "[3]/name", is left out)."""
    fields = line.split()
    if len(fields) < 4:
        return None
    start = line.find(" /")
    if start < 0:
        return None
    rest = line[start + 1:].rstrip()
    try:
        before, process = rest.rsplit(None, 1)
    except ValueError:
        return None
    before = before.rstrip()
    if before.endswith(" W"):
        before = before[:-2].rstrip()
    parts = before.rsplit(None, 1)
    if len(parts) == 2 and re.fullmatch(r"\d+\.\d+", parts[1]):
        before = parts[0]
    path = before.rstrip()
    failed = FAILED.match(line)
    return fields[1].split("[")[0], int(failed.group(1)) if failed else None, path, process


def normalized(path, real_home):
    at = path.find(HOME_MARK + "/")
    if at >= 0:
        return "<home>" + path[at + len(HOME_MARK):]
    if path.endswith(HOME_MARK):
        return "<home>"
    if real_home and (path == real_home or path.startswith(real_home + "/")):
        return "~" + path[len(real_home):]
    return path


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("trace")
    parser.add_argument("--real-home", default="")
    parser.add_argument("--process", default="LumenProfile")
    parser.add_argument("--limit", type=int, default=120)
    args = parser.parse_args(argv)
    missing, refused, account, opened = Counter(), Counter(), Counter(), Counter()
    lines = 0
    with open(args.trace, errors="replace") as trace:
        for line in trace:
            parsed = parse(line)
            if not parsed:
                continue
            call, errno, path, process = parsed
            if not process.startswith(args.process):
                continue
            lines += 1
            where = normalized(path, args.real_home)
            name = NAMES.get(errno, f"errno {errno}") if errno else ""
            if errno == 2 and where.startswith("<home>/Library"):
                missing[(call, where)] += 1
            if errno in (1, 13):
                refused[(name, call, where)] += 1
            if where.startswith("~/Library") and "pb-address-bar-" not in where:
                account[(name or "ok", call, where)] += 1
            if errno is None and call in OPENS and where.startswith("<home>/Library/Safari/"):
                opened[where] += 1
    print(f"STORES-TRACE {lines} call(s) with a whole path by the {args.process} processes")
    if not lines:
        print("STORES-TRACE SKIPPED: the trace holds nothing of the profiles' processes (fs_usage not given their name, or no sudo)")
        return 1
    print(f"STORES-TRACE looked for in the profile's home and not found (ENOENT): {len(missing)} path(s)")
    for (call, where), count in sorted(missing.items(), key=lambda item: (-item[1], item[0][1]))[:args.limit]:
        print(f"STORES-TRACE   ENOENT ×{count} {call} {where}")
    print(f"STORES-TRACE refused (EPERM, EACCES): {len(refused)} path(s)")
    for (name, call, where), count in sorted(refused.items(), key=lambda item: (-item[1], item[0][2]))[:args.limit]:
        print(f"STORES-TRACE   {name} ×{count} {call} {where}")
    print(f"STORES-TRACE asked of the account's own ~/Library (outside the vault): {len(account)} path(s)")
    for (name, call, where), count in sorted(account.items(), key=lambda item: (-item[1], item[0][2]))[:args.limit]:
        print(f"STORES-TRACE   {name} ×{count} {call} {where}")
    print(f"STORES-TRACE opened in the home's Library/Safari: {len(opened)} path(s)")
    for where, count in sorted(opened.items())[:args.limit]:
        print(f"STORES-TRACE   opened ×{count} {where}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
