#!/usr/bin/env python3
"""Every item of Safari's menu bar chosen in a profile's own process, what each did, and whether
that is still what it did when the record was made.

    python3 scripts/menu_walk.py --app build/unsandboxed/PrivacyBrowser.app --out build/menu-walk \\
        --title "Menu walk" [--record docs/menu-walk/safari-26.json] [--check] [--write-record FILE]

Runs `PrivacyBrowser --menu-walk` (SafariMenuWalkCheck.swift, SafariMenuWalk.swift) with the
self-test proxy started for it (the profile's start page loads through it), reads its `MENUWALK`
lines, and adds the crash report of every item that ended the process (scripts/crash_summary.py).
Writes `menu-walk.json` and `menu-walk.md` (a table: item, keys, what it did, what it wrote,
which services started) into --out.

While it walks, `fs_usage` traces the file-system calls of the app's processes, WebKit's and
cfprefsd (as the self-test's disk check does, scripts/disk_check.py; with sudo, when there is no
other kernel trace): a write in the real Safari's places by one of them is a write by the profile.
FSEvents, which the walk reads per item, does not say who wrote, and macOS's own daemons write in
those places on their own schedule (Safari's bookmarks sync agent, its cache-delete extension).

Each item is reduced to what is compared: its behaviour (disabled, a crash or a hang, an
exception, our "unavailable" notice, a panel, an alert, a modal window, a window or sheet by class,
a request to open something outside, quitting, our Settings asked for, a change in the window, or
nothing seen), where it wrote (the profile's home, the real Safari's places, elsewhere) and the
XPC services it started. With --record, the record for this Safari is compared item by item:
every item whose reduction changed fails with --check (exit 1); every item gone and every new one
is listed. Without a record, or with --write-record, the reduction is written
for the record. A walk that did not get to the end fails with --check too, and so does a write in
the real Safari's places that the trace puts on the profile.
"""
import argparse
import glob
import json
import os
import re
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = "Contents/MacOS/PrivacyBrowser"
PROXY_PORT = 18190


def notice(kind, title, text):
    print(f"::{kind} title={title}::{text[:1500]}", flush=True)


def wait_for_port(port, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.5)
    return False


def behaviour(item):
    """What an item did, as a sorted list of words that change only when the behaviour does."""
    if item.get("skipped"):
        return ["not chosen: " + ("services" if "Services" in item["skipped"] else "a view")]
    if "exit" in item:
        return ["hang" if item.get("hang") else "crash"]
    if not item.get("enabled"):
        return ["disabled"]
    words = set()
    for effect in item.get("effects", []):
        for pattern, word in ((r"^an open panel", "open panel"), (r"^a save panel", "save panel"),
                              (r"^an alert", "alert"), (r"^printing", "print"), (r"^page setup", "page setup"),
                              (r"modal", "modal window"), (r"^asks the system to open the file", "opens a file outside"),
                              (r"^asks the system to open", "opens a URL outside"), (r"^asks .* to open", "opens a URL outside"),
                              (r"^asks the system to start", "starts an application"), (r"^asks the Finder", "Finder"),
                              (r"^shares", "shares"), (r"^the sharing menu", "sharing menu"), (r"Help", "Help"),
                              (r"character viewer", "character viewer"), (r"^asks to quit", "quit"),
                              (r"^asks to hide the other", "hides other apps"), (r"^our notice", "our notice"),
                              (r"^nothing in the responder chain", "not taken"), (r"^another application started", "starts another app"),
                              (r"^another application came to the front", "another app in front"),
                              (r"Settings", "our Settings")):
            if re.search(pattern, effect):
                words.add(word)
                break
        else:
            match = re.match(r"^(a window|a sheet): (\S+)", effect)
            if match:
                words.add(f"{match.group(1).split()[1]} {match.group(2)}")
    # Which part of the window changed (key window, first responder, page, zoom) follows the
    # state the items before left and how fast a page loaded: the record keeps that it changed.
    if item.get("changes"):
        words.add("changes the window")
    if item.get("exceptions"):
        names = sorted({entry.split(":")[0] for entry in item["exceptions"]})
        words.add("exception " + ", ".join(names))
    return sorted(words) or ["nothing seen"]


# The account's home outside the profile, by what a write there would mean. Everything else in
# it is written all the time by the system's own daemons (Spotlight, Duet, IdentityServices…),
# whatever runs: listed in the JSON, not counted as the item's.
BUNDLE_ID = "dev.local.PrivacyBrowser"
PLACES = (("this app's files in the account's home", lambda path: BUNDLE_ID in path),
          ("the user's folders", lambda path: path.startswith(("~/Downloads", "~/Desktop", "~/Documents", "~/Pictures", "~/Movies", "~/Music"))),
          ("the keychain", lambda path: path.startswith("~/Library/Keychains")),
          ("recent items", lambda path: "com.apple.sharedfilelist" in path or "RecentDocuments" in path))


def outside(item):
    """The writes outside the profile that count: the places in PLACES."""
    return [path for path in item.get("outside", []) if any(test(path) for _, test in PLACES)]


def writes(item):
    places = []
    if item.get("home"):
        places.append("profile's home")
    if item.get("realSafari"):
        places.append("REAL SAFARI")
    for name, test in PLACES:
        if any(test(path) for path in item.get("outside", [])):
            places.append(name)
    return places


def steady(words):
    """Of an item's behaviour, what does not follow timing: runs 463 and 468 read the same items
    once as "changes the window", once as "nothing seen"; AppKit's own layout exception
    (NSGenericException) came and went; and windows AppKit makes for a moment (a full-screen
    transition's) or that a later item already took back are seen or not. Sheets and panels stay,
    and every other word."""
    kept = []
    for word in words:
        if word in ("changes the window", "nothing seen"):
            continue
        if word.startswith("window ") and not word.startswith("window NSPanel"):
            continue
        if word.startswith("exception "):
            names = [name for name in word[len("exception "):].split(", ") if name != "NSGenericException"]
            if not names:
                continue
            word = "exception " + ", ".join(names)
        kept.append(word)
    return kept or ["-"]


# Items enabled or not by the system's state rather than by the build: Stop Speaking while the
# speech Start Speaking began goes on (run 470, macOS 26: it had ended), Start Dictation… while the
# system's dictation is there (runs 471 and 474, macOS 27: once enabled, once not). Whether they
# were disabled is not compared; what they did when chosen is.
ENABLED_BY_THE_SYSTEM = {"stopSpeaking:", "startDictation:"}


def reduce(item):
    """What the record keeps of an item: what it did (`steady`) and the services it started. Where
    it wrote is in the table but not in the record: a file is written a moment after the item that
    caused it, often during the next one, and the system's daemons write in the home all the time,
    so which item a write belongs to is a guess. What is checked of writes is the walk's as a whole
    (`traced_writes`): nothing in the real Safari's places by the profile, ever."""
    words = steady(behaviour(item))
    if item.get("action") in ENABLED_BY_THE_SYSTEM:
        words = [word for word in words if word != "disabled"] or ["-"]
    return {"behaviour": words, "xpc": sorted(set(item.get("xpc", [])))}


def walk_writes(items):
    """Every write of the walk in the places that count, by place."""
    found = {"REAL SAFARI": set()}
    for item in items:
        found["REAL SAFARI"].update(item.get("realSafari", []))
        for name, test in PLACES:
            found.setdefault(name, set()).update(path for path in item.get("outside", []) if test(path))
    return {name: sorted(paths) for name, paths in found.items()}


def key(item):
    """The item's name in the record: its path, action and keys. A window of the profile listed
    in the Window menu is named by what it is, not by its title (which is the page's)."""
    path = item.get("path", "?")
    if item.get("action") == "makeKeyAndOrderFront:" and path.startswith("Window ›"):
        path = "Window › (a window of the profile)"
    return f"{path} | {item.get('action', '-')} | {item.get('keys', '-')}"


def keyed(items):
    """The items by key; an item whose key repeats (Safari has a few items twice, one hidden) gets
    its place among them after it."""
    named, seen = {}, {}
    for item in items:
        name = key(item)
        seen[name] = seen.get(name, 0) + 1
        named[name if seen[name] == 1 else f"{name} #{seen[name]}"] = item
    return named


def start_trace(out):
    """fs_usage of the app's, WebKit's and cfprefsd's file-system calls, into out/fs.txt; None
    without sudo."""
    if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
        return None
    trace = subprocess.Popen(["sudo", "-n", "fs_usage", "-w", "-f", "filesys", "PrivacyBrowser", "com.apple.WebKit", "cfprefsd"],
                             stdout=open(os.path.join(out, "fs.txt"), "w"), stderr=subprocess.STDOUT)
    time.sleep(2)
    return trace


def start_log(out):
    """The unified log while the walk runs (a measurement): launchd's lines about Safari's services
    and agents — which started, and on whose request — and the keychain's, into out/log.ndjson."""
    predicate = ('(process == "launchd" AND eventMessage CONTAINS[c] "safari") OR '
                 '(subsystem == "com.apple.securityd" AND eventMessage CONTAINS[c] "keychain")')
    sudo = ["sudo", "-n"] if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0 else []
    return subprocess.Popen(sudo + ["log", "stream", "--style", "ndjson", "--level", "info", "--predicate", predicate],
                            stdout=open(os.path.join(out, "log.ndjson"), "w"), stderr=subprocess.STDOUT)


def logged(out):
    """What the log said: launchd's distinct lines about Safari's services, and who the keychain's
    lines were for, by process."""
    services, keychain = {}, {}
    try:
        lines = open(os.path.join(out, "log.ndjson"), encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return [], {}
    for line in lines:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        message = entry.get("eventMessage", "")
        if entry.get("processImagePath", "").endswith("/launchd"):
            # Addresses and pids vary from run to run; the line's words do not.
            words = re.sub(r"\b0x[0-9a-f]+\b|\[\d+\]|\b\d{3,}\b", "#", message)[:240]
            services[words] = services.get(words, 0) + 1
        else:
            who = os.path.basename(entry.get("processImagePath", "?"))
            keychain[who] = keychain.get(who, 0) + 1
    return sorted(services.items(), key=lambda item: -item[1]), keychain


def traced_writes(out):
    """The writes in the real Safari's places in out/fs.txt, as "process: path", and what the
    trace was (lines read, or why it is none)."""
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import disk_check
    path_of_trace = os.path.join(out, "fs.txt")
    if not os.path.exists(path_of_trace):
        return [], "no trace (no sudo)"
    with open(path_of_trace, encoding="utf-8", errors="replace") as handle:
        head = [line for _, line in zip(range(10), handle)]
    if len(head) < 10 and any("ktrace" in line or "Resource busy" in line for line in head):
        return [], "no trace: " + " ".join(head)[:200]
    roots = disk_check.forbidden_roots(os.path.expanduser("~"))
    found = []
    kept = []
    count = 0
    for line in open(path_of_trace, encoding="utf-8", errors="replace"):
        count += 1
        line = line.rstrip("\n")
        fields = line.split()
        if len(fields) < 3:
            continue
        call = fields[1].split("[")[0]
        writes = call in disk_check.WRITES or (call in disk_check.OPENS and re.search(r"\([^)]*[WC][^)]*\)", line))
        if not writes or disk_check.FAILED.match(line):
            continue
        for path in disk_check.PATH.findall(line):
            path = path.replace("\\ ", " ")
            if disk_check.is_forbidden(path, roots):
                found.append(f"{fields[-1].rsplit('.', 1)[0]}: {path}")
                kept.append(line)
    # The whole trace is hundreds of megabytes; what is kept is what counted.
    with open(os.path.join(out, "fs-real-safari.txt"), "w") as handle:
        handle.write("\n".join(kept) + ("\n" if kept else ""))
    os.remove(path_of_trace)
    return sorted(set(found)), f"{count} lines traced"


def crash_reports(since, out):
    """The crash reports of this app's processes written since `since`, summarized, by pid."""
    found = {}
    for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/PrivacyBrowser*.ips")):
        if os.path.getmtime(path) < since:
            continue
        summary = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "crash_summary.py"), path],
                                 capture_output=True, text=True).stdout
        match = re.search(r"\(pid (\d+)\)", summary)
        found[path] = (int(match.group(1)) if match else None, summary)
        with open(os.path.join(out, os.path.basename(path) + ".txt"), "w") as handle:
            handle.write(summary)
    return found


def table(items):
    lines = ["| # | Item | Keys | What it did | Wrote | Services |", "|---|---|---|---|---|---|"]
    for item in items:
        reduced = reduce(item)
        did = "; ".join(reduced["behaviour"])
        details = [effect for effect in item.get("effects", [])] + item.get("exceptions", [])[:2]
        if details:
            did += "<br><sub>" + " · ".join(text.replace("|", "/")[:200] for text in details[:4]) + "</sub>"
        wrote = ", ".join(writes(item)) or "—"
        lines.append(f"| {item.get('index', '?')} | {item.get('path', '?').replace('|', '/')} | {item.get('keys', '-')} "
                     f"| {did} | {wrote} | {', '.join(reduced['xpc'] + [a + ' (agent)' for a in item.get('agents', [])]) or '—'} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default="Menu walk")
    parser.add_argument("--record", help="the record of this Safari's menu walk to compare with")
    parser.add_argument("--check", action="store_true", help="fail when the walk differs from the record")
    parser.add_argument("--write-record", help="write this walk's reduction here")
    parser.add_argument("--ignore", default="", help="prefixes of files written by others, colon-separated")
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    global BUNDLE_ID
    try:
        import plistlib
        with open(os.path.join(args.app, "Contents", "Info.plist"), "rb") as handle:
            BUNDLE_ID = plistlib.load(handle).get("CFBundleIdentifier", BUNDLE_ID)
    except (OSError, ValueError):
        pass

    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "selftest_proxy.py"),
                              "--http", str(PROXY_PORT), "--socks", str(PROXY_PORT + 1)],
                             stdout=open(os.path.join(out, "proxy.txt"), "w"), stderr=subprocess.STDOUT)
    proxied = wait_for_port(PROXY_PORT)
    environment = dict(os.environ, PRIVACYBROWSER_LANG="en", PB_MENU_WALK_IGNORE=args.ignore)
    if proxied:
        environment["PB_SELFTEST_HTTP_PROXY_PORT"] = str(PROXY_PORT)
    trace = start_trace(out)
    log_stream = start_log(out)
    started = time.time()
    with open(os.path.join(out, "walk.txt"), "w") as log:
        try:
            result = subprocess.run([os.path.join(args.app, BINARY), "--menu-walk"], env=environment,
                                    stdout=subprocess.PIPE, stderr=log, text=True, timeout=2700)
            output, status = result.stdout, result.returncode
        except subprocess.TimeoutExpired as expired:
            output, status = (expired.stdout or b"").decode(errors="replace") if isinstance(expired.stdout, bytes) else (expired.stdout or ""), -1
        log.write(output)
    proxy.kill()
    subprocess.run(["sudo", "-n", "kill", "-INT", str(log_stream.pid)], capture_output=True)
    try:
        log_stream.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            log_stream.terminate()
        except OSError:
            pass
    if trace:
        subprocess.run(["sudo", "-n", "pkill", "-INT", "-f", "fs_usage -w"], capture_output=True)
        time.sleep(2)
    by_profile, traced = traced_writes(out)
    print(f"MENU-WALK file trace: {traced}; writes in the real Safari's places by the app's, WebKit's or cfprefsd's "
          f"processes: {len(by_profile)}", flush=True)
    services, keychain = logged(out)
    print(f"MENU-WALK launchd on Safari's services and agents during the walk: {len(services)} distinct lines", flush=True)
    for words, count in services[:40]:
        print(f"MENU-WALK   launchd x{count}: {words}", flush=True)
    print(f"MENU-WALK the keychain's lines during the walk, by process: {keychain or 'none'}", flush=True)

    items = []
    for line in output.splitlines():
        if line.startswith("MENUWALK "):
            try:
                items.append(json.loads(line[len("MENUWALK "):]))
            except ValueError:
                pass
        elif line.startswith(("MENUWALK-INFO", "MENUWALK-ERROR")):
            print(line, flush=True)
    finished = "the walk got to the end" in output
    # A view whose service the profile is refused, asked for again each time that service ends, is
    # this line each time: SafariPlatformSupport's completion list did so about a million times a
    # walk until it was stopped (measurement runs 468 to 475), twenty times since (run 476).
    with open(os.path.join(out, "walk.txt"), encoding="utf-8", errors="replace") as handle:
        refused_views = sum(1 for line in handle if "listener 'com.apple.view-bridge'" in line)
    print(f"MENU-WALK views asked for again after their service was refused: {refused_views}", flush=True)
    reports = crash_reports(started, out)
    for item in items:
        if "exit" in item:
            # The report of a process that ended while this item ran: written after its begin.
            near = [summary for path, (pid, summary) in reports.items() if os.path.getmtime(path) >= item.get("begin", 0) - 1]
            item["crashReport"] = near[0].splitlines()[:30] if near else ["no crash report found"]
    with open(os.path.join(out, "menu-walk.json"), "w") as handle:
        json.dump(items, handle, indent=1, ensure_ascii=False)
    with open(os.path.join(out, "menu-walk.md"), "w") as handle:
        handle.write(table(items))

    counts = {}
    for item in items:
        for word in behaviour(item):
            counts[word] = counts.get(word, 0) + 1
    notice("notice", args.title, f"{len(items)} items walked (exit {status}, {'to the end' if finished else 'NOT to the end'}); "
           + "; ".join(f"{word}: {count}" for word, count in sorted(counts.items(), key=lambda entry: -entry[1])[:25]))
    for item in items:
        reduced = reduce(item)
        flagged = [word for word in reduced["behaviour"] if word in ("crash", "hang") or word.startswith("exception")]
        places = writes(item)
        if flagged or "REAL SAFARI" in places:
            detail = "; ".join(reduced["behaviour"]) + (f" — wrote meanwhile: {', '.join(places)}" if places else "")
            extra = (item.get("exceptions") or [])[:1] + (item.get("realSafari") or [])[:3] + (item.get("crashReport") or [])[:6]
            notice("warning", args.title, f"{key(item)}: {detail}. " + " · ".join(extra))
    written = walk_writes(items)
    for name, paths in written.items():
        if paths:
            notice("warning", args.title, f"during the walk, written in {name} (by any process): {len(paths)} path(s): "
                   + " · ".join(paths[:8]))
    if by_profile:
        notice("error" if args.check else "warning", args.title,
               f"the profile wrote in the real Safari's places (fs_usage): " + " · ".join(by_profile[:8]))

    current = {name: reduce(item) for name, item in keyed(items).items()}
    if args.write_record or not args.record or not os.path.exists(args.record or ""):
        target = args.write_record or os.path.join(out, "record.json")
        with open(target, "w") as handle:
            json.dump(current, handle, indent=1, ensure_ascii=False, sort_keys=True)
        print(f"MENU-WALK record written: {target}", flush=True)
    if refused_views > 1000:
        notice("error" if args.check else "warning", args.title,
               f"the profile's process asked {refused_views} times for a view whose service it is refused: a loop")
    failed = args.check and (not finished or bool(by_profile) or refused_views > 1000)
    if args.record and os.path.exists(args.record):
        with open(args.record) as handle:
            recorded = json.load(handle)
        # An item whose steady behaviour changed fails the check; an item that came or went is
        # said: which items a menu has follows the window's state and, on Safari 27, the runner
        # (Import Browsing Data in some runs, Import From › Bookmarks HTML File in others, either Safari).
        differences, comings = [], []
        for name in sorted(set(recorded) | set(current)):
            if name not in current:
                comings.append(f"gone: {name}")
            elif name not in recorded:
                comings.append(f"new: {name} — {'; '.join(current[name]['behaviour'])}")
            elif recorded[name] != current[name]:
                was, now = recorded[name], current[name]
                differences.append(f"changed: {name} — was {was}, now {now}")
        for difference in differences[:60]:
            notice("error" if args.check else "warning", args.title, difference)
        for coming in comings[:30]:
            notice("warning", args.title, coming)
        print(f"MENU-WALK {len(differences)} item(s) that changed, {len(comings)} that came or went, "
              f"from the record {args.record}", flush=True)
        if differences and args.check:
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
