#!/usr/bin/env python3
"""Does a profile's process (or the WebKit processes working for it) write outside its own home?

    sudo fs_usage -w -f filesys PrivacyBrowser com.apple.WebKit cfprefsd > fs.txt &
    PrivacyBrowser --self-test | tee selftest.txt
    python3 scripts/disk_check.py --trace fs.txt --selftest-log selftest.txt

(One fs_usage for all the processes: the kernel trace is exclusive, and a second fs_usage
sees nothing.)

A profile whose window is Safari's chrome runs Safari's own frameworks, which keep their history,
tab snapshots, per-site settings and preferences in the user's home. In a profile's process that
home is the profile's own (`CFFIXED_USER_HOME`), sealed with the profile. Anything those frameworks —
or anything else in the app — write where the real Safari keeps its data would be both a leak (the
profile's browsing in the user's Safari) and pollution of it, and is outside every encrypted archive.

`fs_usage` records every file-system call of the processes named; this reads the ones that create,
write, rename or remove, during the self-test's Safari-chrome check (`INFO egress-window ...`), and
fails on any path in the real Safari's places:

    ~/Library/Safari, ~/Library/Containers/com.apple.Safari*, ~/Library/Group Containers/*Safari*,
    ~/Library/Cookies, ~/Library/Caches/com.apple.Safari, ~/Library/WebKit/com.apple.Safari,
    ~/Library/Preferences/com.apple.Safari*.plist, ~/Library/HTTPStorages/com.apple.Safari

Every other path written outside the self-test's temporary vault is listed by directory, so that
what the app leaves behind is visible run after run. A call that failed (fs_usage shows its errno,
`[  1]` for a sandbox's refusal) wrote nothing: those are listed as refused, never failed on.
cfprefsd's calls are traced too: it writes every preferences file through a directory descriptor,
and `Resolver` names those paths whole. What it writes in the real Safari's places is listed, not
failed on — it writes for whichever process asks, and the trace cannot say which — and with
--canary, a preferences file written through it while the trace ran must be named, or the trace is
blind to cfprefsd (exit 1). A trace that could not be made is a warning (exit 0); a write to the
real Safari's places by the app's or WebKit's processes is exit 1.
"""
import argparse
import os
import re
import sys
from collections import Counter

WRITES = {"mkdir", "rename", "renameat", "renamex_np", "unlink", "unlinkat", "rmdir", "truncate", "ftruncate",
          "WrData", "WrMeta", "write", "pwrite", "writev", "chmod", "fchmod", "chown", "setxattr", "fsetxattr",
          "removexattr", "link", "symlink", "clonefile", "clonefileat", "copyfile", "exchangedata", "utimes", "futimes"}
OPENS = {"open", "openat", "open_nocancel", "openat_nocancel", "open_extended", "creat"}
TIME = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d+)")
# "15:42:15.747185  unlink  [  2]  /Users/..." — the call failed with that errno; not "[6]//…" or
# "[3]/name", a path given with a directory descriptor (a renameat of cfprefsd's reads so).
FAILED = re.compile(r"^\S+\s+\S+\s+\[\s*(\d+)\](?!/)")
PATH = re.compile(r"(/(?:[^\s]|\\ )+)")
# "[3]/name": a path relative to a directory descriptor (openat, renameat, fstatat…); "[-2]/…" is the
# current directory's, with an absolute path; "[6]//private/…", an absolute path given with a descriptor.
RELATIVE = re.compile(r"\[(-?\d+)\](/(?:[^\s]|\\ )*)")
DESCRIPTOR = re.compile(r"\bF=(\d+)")
RENAMES = {"rename", "renameat", "renamex_np", "renameatx_np"}


class Resolver:
    """fs_usage's paths, whole. cfprefsd writes every preferences file the same way: it opens the
    file's directory, opens the file relative to it to create it ("[3]/name.plist"), writes a
    temporary file in its own temporary folder and renames that onto the file — and fs_usage names
    only the rename's source (CI's measurement run 521, a canary domain by name, by a path in a home
    and by a path in a container, on macOS 26 and 27). So a path relative to a descriptor is named by
    the path that descriptor was opened on, as the same process opened it earlier in the trace, and a
    rename of a temporary file onto a file the process opened to create is that file. A descriptor
    opened before the trace began stays "[N?]/name"."""

    def __init__(self):
        self.descriptors = {}
        self.created = {}

    def paths(self, line):
        """The paths of one line of the trace, whole, and those it writes to the process's records."""
        fields = line.split()
        if len(fields) < 3:
            return []
        process = fields[-1]
        call = fields[1].split("[")[0]
        table = self.descriptors.setdefault(process, {})
        found = []
        for match in RELATIVE.finditer(line):
            descriptor, rest = int(match.group(1)), match.group(2)
            if rest.startswith("//") or descriptor == -2:
                found.append(rest[1:] if rest.startswith("//") else rest)
            elif descriptor in table:
                found.append(table[descriptor] + rest)
            else:
                found.append(f"[{descriptor}?]{rest}")
        found += PATH.findall(RELATIVE.sub(" ", line))
        found = [path.replace("\\ ", " ") for path in found]
        opened = DESCRIPTOR.search(line)
        if call == "close" and opened:
            table.pop(int(opened.group(1)), None)
        elif call in OPENS and opened and found and not FAILED.match(line):
            table[int(opened.group(1))] = found[0]
            if re.search(r"\([^)]*C[^)]*\)", line):
                self.created.setdefault(process, {})[os.path.basename(found[0])] = found[0]
        if call in RENAMES and found and not FAILED.match(line):
            target = self.created.get(process, {}).get(os.path.basename(found[0]).rsplit(".", 1)[0])
            if target:
                found.append(target)
        return found


def forbidden_roots(home):
    library = os.path.join(home, "Library")
    return [os.path.join(library, "Safari"), os.path.join(library, "Containers", "com.apple.Safari"),
            os.path.join(library, "Cookies"), os.path.join(library, "Caches", "com.apple.Safari"),
            os.path.join(library, "WebKit", "com.apple.Safari"), os.path.join(library, "Preferences", "com.apple.Safari"),
            os.path.join(library, "HTTPStorages", "com.apple.Safari"), os.path.join(library, "Group Containers")]


def is_forbidden(path, roots):
    for root in roots:
        if root.endswith("Group Containers"):
            if path.startswith(root + "/") and "safari" in path[len(root):].lower():
                return True
        elif path == root or path.startswith(root + "/") or path.startswith(root + "."):
            return True
    return False


def seconds_of_day(line):
    match = TIME.match(line)
    if not match:
        return None
    hours, minutes, seconds, fraction = match.groups()
    return int(hours) * 3600 + int(minutes) * 60 + int(seconds) + float("0." + fraction)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", action="append", default=[])
    parser.add_argument("--selftest-log", required=True)
    parser.add_argument("--home", default=os.path.expanduser("~"))
    parser.add_argument("--canary", help="a preferences file cfprefsd wrote while the trace ran (a path domain set "
                                         "with `defaults write`): the trace must name it, or it is blind to cfprefsd")
    args = parser.parse_args()

    log = open(args.selftest_log, encoding="utf-8", errors="replace").read()
    begins = [float(t) for t in re.findall(r"INFO egress-window begin ([\d.]+)", log)]
    ends = [float(t) for t in re.findall(r"INFO egress-window end ([\d.]+)", log)]
    vaults = set(re.findall(r"(/\S*pb-selftest-[0-9A-Fa-f-]+)", log))
    if not begins:
        print("::warning::disk check: the self-test did not run its Safari-chrome check; nothing to look at")
        return 0
    # fs_usage prints the local time of day; the window is in epoch seconds.
    import time
    windows = []
    for index, begin in enumerate(begins):
        end = ends[index] if index < len(ends) else begin + 3600
        start_tm, end_tm = time.localtime(begin), time.localtime(end)
        windows.append((start_tm.tm_hour * 3600 + start_tm.tm_min * 60 + start_tm.tm_sec + (begin % 1),
                        end_tm.tm_hour * 3600 + end_tm.tm_min * 60 + end_tm.tm_sec + (end % 1)))

    roots = forbidden_roots(args.home)
    failures, refused, elsewhere, lines_read = [], [], Counter(), 0
    by_cfprefsd, canary_seen = [], False
    for trace in args.trace:
        try:
            lines = open(trace, encoding="utf-8", errors="replace").read().splitlines()
        except OSError as error:
            print(f"::warning::disk check: no trace {trace} ({error})")
            continue
        if len(lines) < 10 and any("ktrace" in line or "Resource busy" in line for line in lines):
            print(f"::warning::disk check: {trace} is not a trace ({' '.join(lines)[:200]}): another kernel trace held it")
            continue
        lines_read += len(lines)
        print(f"disk check: {trace}: {len(lines)} lines; first ones, for the format:")
        for line in lines[:3]:
            print("   ", line[:200])
        resolver = Resolver()
        for line in lines:
            paths = resolver.paths(line)
            fields = line.split()
            if len(fields) < 2:
                continue
            call = fields[1].split("[")[0]
            writes = call in WRITES or (call in OPENS and re.search(r"\([^)]*[WC][^)]*\)", line) is not None)
            if not writes:
                continue
            cfprefsd = fields[-1].startswith("cfprefsd.")
            if args.canary and cfprefsd and args.canary in paths:
                canary_seen = True
            when = seconds_of_day(line)
            if when is None or not any(start - 1 <= when <= end + 1 for start, end in windows):
                continue
            for path in paths:
                if path.startswith("/dev/") or any(path.startswith(v) or path.startswith("/private" + v) for v in vaults):
                    continue
                if is_forbidden(path, roots):
                    if FAILED.match(line):
                        refused.append(line)
                    elif cfprefsd:
                        # cfprefsd writes for whichever process asks it, and the trace does not say which.
                        by_cfprefsd.append(f"{path}  ({line.split()[1]} {fields[-1]})")
                    else:
                        failures.append(line)
                elif path.startswith(args.home) or path.startswith("/private/var/folders") or path.startswith("/var/folders"):
                    parts = path.split("/")
                    elsewhere["/".join(parts[:7])] += 1
    if lines_read == 0:
        print("::warning::disk check inconclusive: no fs_usage trace")
        return 0
    if elsewhere:
        print("written outside the self-test's vault during the check (listed, not failed on):")
        for directory, count in elsewhere.most_common(40):
            print(f"  {count:6d}  {directory}")
    if args.canary:
        if canary_seen:
            print(f"disk check: the trace names cfprefsd's write of the canary, {args.canary}")
        else:
            print(f"::error::disk check: the trace does not name cfprefsd's write of the canary {args.canary}: "
                  "it is blind to cfprefsd again")
    if by_cfprefsd:
        print(f"::warning::disk check: cfprefsd wrote {len(set(by_cfprefsd))} file(s) in the real Safari's places while a "
              "profile ran, for a process the trace cannot name (listed, not failed on):")
        for entry in sorted(set(by_cfprefsd))[:30]:
            print("CFPREFSD " + entry[:300])
    if refused:
        print(f"disk check: {len(refused)} calls into the real Safari's places were refused (they wrote nothing):")
        for line in refused[:20]:
            print("REFUSED " + line[:300])
    if failures:
        print(f"::error::disk check: {len(failures)} writes into the real Safari's places while a profile ran")
        for line in failures[:60]:
            print("WRITE " + line[:300])
        return 1
    if args.canary and not canary_seen:
        return 1
    print("disk check: nothing was written into the real Safari's places by the app's or WebKit's processes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
