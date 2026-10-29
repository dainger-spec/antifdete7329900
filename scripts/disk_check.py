#!/usr/bin/env python3
"""Does a profile's process (or the WebKit processes working for it) write outside its own home?

    sudo fs_usage -w -f filesys PrivacyBrowser   > fs-app.txt &
    sudo fs_usage -w -f filesys com.apple.WebKit > fs-webkit.txt &
    PrivacyBrowser --self-test | tee selftest.txt
    python3 scripts/disk_check.py --trace fs-app.txt --trace fs-webkit.txt --selftest-log selftest.txt

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
`[  1]` for a sandbox's refusal) wrote nothing: those are listed as refused, never failed on. A
trace of cfprefsd (`sudo fs_usage -w -f filesys cfprefsd`) counts as well, for the preferences a
profile's process sets through it. A trace that could not be made is a warning (exit 0); a write
to the real Safari's places is exit 1.
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
# "15:42:15.747185  unlink  [  2]  /Users/..." — the call failed with that errno.
FAILED = re.compile(r"^\S+\s+\S+\s+\[\s*(\d+)\]")
PATH = re.compile(r"(/(?:[^\s]|\\ )+)")


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
    for trace in args.trace:
        try:
            lines = open(trace, encoding="utf-8", errors="replace").read().splitlines()
        except OSError as error:
            print(f"::warning::disk check: no trace {trace} ({error})")
            continue
        lines_read += len(lines)
        print(f"disk check: {trace}: {len(lines)} lines; first ones, for the format:")
        for line in lines[:3]:
            print("   ", line[:200])
        for line in lines:
            when = seconds_of_day(line)
            if when is None or not any(start - 1 <= when <= end + 1 for start, end in windows):
                continue
            fields = line.split()
            if len(fields) < 2:
                continue
            call = fields[1].split("[")[0]
            writes = call in WRITES or (call in OPENS and re.search(r"\([^)]*[WC][^)]*\)", line) is not None)
            if not writes:
                continue
            for path in PATH.findall(line):
                path = path.replace("\\ ", " ")
                if path.startswith("/dev/") or any(path.startswith(v) or path.startswith("/private" + v) for v in vaults):
                    continue
                if is_forbidden(path, roots):
                    (refused if FAILED.match(line) else failures).append(line)
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
    if refused:
        print(f"disk check: {len(refused)} calls into the real Safari's places were refused (they wrote nothing):")
        for line in refused[:20]:
            print("REFUSED " + line[:300])
    if failures:
        print(f"::error::disk check: {len(failures)} writes into the real Safari's places while a profile ran")
        for line in failures[:60]:
            print("WRITE " + line[:300])
        return 1
    print("disk check: nothing was written into the real Safari's places")
    return 0


if __name__ == "__main__":
    sys.exit(main())
