#!/usr/bin/env python3
"""Measurement only, never merged: what scripts/measure/pbtrace.c wrote, and what the kernel's sandbox
reports and secd said about the same processes, summed up.

    pbtrace_report.py --trace trace.txt [--log log.ndjson] --title NAME

Prints, for the profile's processes (argv has --profile-session) and the manager apart:
  KEYCHAIN  every call, grouped by function, class, service, access group, synchronizable, the
            data protection keychain flag and status, with the first frames outside Security of
            the first call of the group;
  LOOKUP    every Mach service asked for by name through the calls the library sees, with the
            frames that asked first;
  SANDBOX   every Mach service the kernel reported the profile's process looking up;
  SECD      what secd said about the app's processes (refusals, by operation).
"""
import argparse
import collections
import json
import re

SYSTEM_FRAMES = ("Security ", "libsystem", "libdispatch", "libxpc", "CoreFoundation ", "libobjc", "libdyld",
                 "pbtrace.dylib", "Foundation ", "dyld ", "libswift")


def first_frames(stack, count=7):
    frames = [frame.strip() for frame in stack.split(" < ")]
    useful = [frame for frame in frames if frame and not frame.startswith(SYSTEM_FRAMES)]
    return " < ".join((useful or frames)[:count])


def attribute(text, name):
    match = re.search(r"(?:^|[{ ])" + re.escape(name) + r"=(\"[^\"]*\"|[^ }]+)", text)
    return match.group(1) if match else "-"


def notice(title, text):
    print(f"::notice title={title}::{text}"[:3900], flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True)
    parser.add_argument("--log")
    parser.add_argument("--title", default="trace")
    args = parser.parse_args()

    roles = {}
    keychain = collections.OrderedDict()
    lookups = collections.OrderedDict()
    counts = collections.Counter()
    lines = 0
    try:
        handle = open(args.trace, encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"PBTRACE-REPORT {args.title}: no trace ({error})")
        return 0
    for line in handle:
        lines += 1
        match = re.match(r"PBTRACE (\d+) (\w+) (.*)", line.rstrip("\n"))
        if not match:
            continue
        pid, kind, rest = int(match.group(1)), match.group(2), match.group(3)
        if kind == "PROC":
            roles[pid] = "profile" if "--profile-session" in rest else ("manager" if "PrivacyBrowser" in rest else rest[:60])
            continue
        role = roles.get(pid, f"pid {pid}")
        if kind == "KEYCHAIN":
            call, _, stack = rest.partition(" | ")
            words = call.split(" ", 2)
            function, status = words[0], words[1].replace("status=", "")
            details = words[2] if len(words) > 2 else ""
            group = (role, function, attribute(details, "class"), attribute(details, "svce"), attribute(details, "agrp"),
                     attribute(details, "sync"), attribute(details, "nleg"), status, attribute(details, "name"))
            entry = keychain.setdefault(group, {"count": 0, "details": details[:600], "stack": first_frames(stack)})
            entry["count"] += 1
        elif kind == "LOOKUP":
            call, _, stack = rest.partition(" | ")
            name = re.search(r"name=(\S+)", call)
            function = call.split(" ", 1)[0]
            key = (role, function, name.group(1) if name else "?")
            lookups.setdefault(key, first_frames(stack, 5))
        elif kind == "LOOKUPCOUNT":
            words = rest.split(" ", 2)
            if len(words) == 3:
                counts[(role, words[1], words[2])] += int(words[0])

    print(f"PBTRACE-REPORT {args.title}: {lines} lines; processes: "
          + ", ".join(f"{pid}={role}" for pid, role in sorted(roles.items())), flush=True)
    for (role, function, klass, service, group, sync, nleg, status, name), entry in keychain.items():
        text = (f"{args.title} KEYCHAIN {role}: {function} x{entry['count']} class={klass} svce={service} agrp={group} "
                f"sync={sync} nleg={nleg} name={name} status={status} — {entry['details'][:300]} — first by: {entry['stack']}")
        print("PBTRACE-KEYCHAIN " + text, flush=True)
        notice(f"{args.title} keychain", text)
    if not keychain:
        print(f"PBTRACE-KEYCHAIN {args.title}: no keychain call seen", flush=True)
    by_role = collections.defaultdict(list)
    for (role, function, name), stack in lookups.items():
        total = counts.get((role, function, name), 1)
        by_role[role].append((name, function, total, stack))
    for role, entries in by_role.items():
        names = sorted({name for name, _, _, _ in entries})
        print(f"PBTRACE-LOOKUPS {args.title} {role}: {len(names)} name(s): " + ", ".join(names), flush=True)
        notice(f"{args.title} lookups ({role})", f"{len(names)}: " + ", ".join(names))
        for name, function, total, stack in sorted(entries):
            print(f"PBTRACE-LOOKUP {args.title} {role}: {name} via {function} x{total} — first by: {stack}", flush=True)

    if args.log:
        reported = collections.Counter()
        secd = collections.Counter()
        profile_pids = {pid for pid, role in roles.items() if role == "profile"}
        try:
            for raw in open(args.log, encoding="utf-8", errors="replace"):
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                message = event.get("eventMessage", "")
                sandbox = re.search(r"Sandbox: (\S+)\((\d+)\) (allow|deny)\S* (mach-lookup|iokit-open\S*) (\S+)", message)
                if sandbox:
                    pid = int(sandbox.group(2))
                    role = "profile" if pid in profile_pids else roles.get(pid, f"{sandbox.group(1)} {pid}")
                    reported[(role, sandbox.group(3), sandbox.group(4), sandbox.group(5))] += 1
                    continue
                refusal = re.search(r"PrivacyBrowser\[(\d+)\]\S* \S+ (add|update|delete|query|copy_matching)\S* Error[^\"]*\"([^\"]*)\"",
                                    message)
                if refusal:
                    pid = int(refusal.group(1))
                    role = "profile" if pid in profile_pids else roles.get(pid, f"pid {pid}")
                    secd[(role, refusal.group(2), refusal.group(3)[:100])] += 1
        except OSError as error:
            print(f"PBTRACE-REPORT {args.title}: no log ({error})")
        names = collections.defaultdict(set)
        for (role, verdict, operation, name), count in sorted(reported.items()):
            print(f"PBTRACE-SANDBOX {args.title} {role}: {verdict} {operation} {name} x{count}", flush=True)
            names[(role, verdict, operation)].add(name)
        for (role, verdict, operation), found in names.items():
            notice(f"{args.title} sandbox ({role})", f"{verdict} {operation}: {len(found)}: " + ", ".join(sorted(found)))
        if not reported:
            print(f"PBTRACE-SANDBOX {args.title}: the kernel reported no Mach lookup of the app's processes", flush=True)
        for (role, operation, reason), count in secd.items():
            text = f"{args.title} SECD {role}: {operation} refused x{count}: {reason}"
            print("PBTRACE-SECD " + text, flush=True)
            notice(f"{args.title} secd", text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
