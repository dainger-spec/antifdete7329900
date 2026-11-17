#!/usr/bin/env python3
"""The sweep: a profile's Safari window driven with real input events, on this Mac as it is set up.

    python3 scripts/sweep.py --app build/unsandboxed/Lumen.app --out build/sweep/<state> --state <name>

Starts the self-test proxy (scripts/selftest_proxy.py: its HTTP and SOCKS5 sides serve the sweep's
pages), runs `Lumen --sweep` (SafariSweepCheck and SafariSweep: one profile in its own process with
Safari's window, its keys, clicks and menus done by the window server's own events), and reads what
each unit did. While it runs, a hang the profile's process announces (`SWEEP-HANG`) has its main
thread written down (spindump as root, else sample). After it: the crash reports of the app's and
WebKit's processes written meanwhile (scripts/crash_summary.py), and the app's exception log.

Writes <out>/sweep.txt (everything the app printed), <out>/units.json, <out>/report.md (also to the
job's summary when $GITHUB_STEP_SUMMARY is set) and GitHub notices for every finding.

A finding is a unit that crashed the process or was killed, an exception AppKit's run loop caught,
a notice the window would have put up ("This Safari feature is unavailable in the profile"), the
main thread stopped for more than two seconds, or a crash report. What a unit expected and did not
see is listed too, as "not as expected". Exit 1 when there is a finding not explained in
--explained (a JSON list of {"unit": regex, "text": regex, "why": "..."}), or the sweep did not get
to its end; 0 otherwise. The environment's PB_SWEEP_* variables pass through to the app.
"""
import argparse
import glob
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEADLINE = 55 * 60
SILENCE = 240
CRASHED = ("LumenProfile", "Lumen", "com.apple.WebKit")


def wait_for_port(port, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.3)
    return False


def main_thread(pid, out, name):
    """The main thread of `pid`, its deepest frames (spindump as root, else sample); the whole
    report in <out>/stack-<name>-<pid>-<n>.txt."""
    existing = len(glob.glob(os.path.join(out, f"stack-{name}-{pid}-*.txt")))
    path = os.path.join(out, f"stack-{name}-{pid}-{existing + 1}.txt")
    said = []
    for command in (["sudo", "-n", "/usr/sbin/spindump", str(pid), "2", "10", "-onlyTarget", "-file", path],
                    ["/usr/bin/sample", str(pid), "2", "-mayDie", "-file", path]):
        try:
            result = subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=120)
        except (OSError, subprocess.TimeoutExpired) as error:
            said.append(str(error))
            continue
        if os.path.exists(path) and os.path.getsize(path) > 0:
            break
        said.append(f"exit {result.returncode}: {' '.join((result.stderr or result.stdout).split())[:200]}")
    else:
        return [f"no stack: {'; '.join(said)}"]
    with open(path, encoding="utf-8", errors="replace") as handle:
        report = handle.read().splitlines()
    start = next((i for i, line in enumerate(report) if "com.apple.main-thread" in line or "Thread 0" in line), None)
    if start is None:
        return [f"no main thread in {path}"]
    frames = []
    for line in report[start + 1:]:
        if not line.strip() or re.match(r"^\s*(Thread 0x|\d+ Thread_)", line):
            break
        frames.append(re.sub(r"^[\s+!:|]*", "", line).rstrip())
    return [f"main thread ({path}):"] + frames[-25:]


def run(command, environment, out, log):
    """Runs the sweep, its output read as it comes; returns (lines, status, stacks by unit index)."""
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=log, text=True,
                               errors="replace", start_new_session=True)
    lines, last = [], [time.time()]
    stacks = {}

    def sample(pid, index):
        stacks.setdefault(str(index), []).append(main_thread(pid, out, "profile"))

    def read():
        for line in process.stdout:
            lines.append(line)
            last[0] = time.time()
            if line.startswith(("SWEEP-PROGRESS", "SWEEP-ERROR", "SWEEP-INFO", "SWEEP-HANG")):
                print(line.rstrip()[:400], flush=True)
            if line.startswith("SWEEP-HANG "):
                parts = line.split()
                if len(parts) >= 3 and parts[1].isdigit() and parts[3:4] != ["killed"] and len(stacks.get(parts[2], [])) < 2:
                    threading.Thread(target=sample, args=(int(parts[1]), parts[2]), daemon=True).start()

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    started, stopped = time.time(), None
    while process.poll() is None:
        now = time.time()
        if now - started > DEADLINE:
            stopped = f"the sweep did not finish in {DEADLINE // 60} minutes"
        elif now - last[0] > SILENCE:
            stopped = f"nothing from the sweep for {SILENCE} s"
        if stopped:
            break
        time.sleep(1)
    if stopped:
        lines.append(f"SWEEP-ERROR {stopped}: stopped here\n")
        print(f"SWEEP-ERROR {stopped}", flush=True)
        for line in main_thread(process.pid, out, "app"):
            lines.append(f"SWEEP-STACK app: {line}\n")
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
                process.wait(timeout=15)
                break
            except (ProcessLookupError, PermissionError, subprocess.TimeoutExpired):
                continue
    reader.join(timeout=15)
    return lines, (-1 if stopped else process.returncode), stacks


def crash_reports(since, out):
    found = []
    for path in sorted(glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*.ips"))):
        name = os.path.basename(path)
        if os.path.getmtime(path) < since or not any(word in name for word in CRASHED):
            continue
        summary = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "crash_summary.py"), path],
                                 capture_output=True, text=True).stdout
        with open(os.path.join(out, name + ".txt"), "w") as handle:
            handle.write(summary)
        found.append((name, summary))
    return found


def exception_log(since, out):
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(since))
    path = os.path.join(out, "exceptions-log.txt")
    with open(path, "w") as handle:
        subprocess.run(["log", "show", "--start", start, "--style", "compact", "--predicate",
                        'subsystem == "PrivacyBrowser" AND (category == "Exception" OR category == "SafariChrome")'],
                       stdout=handle, stderr=subprocess.STDOUT, timeout=300)
    return path


def findings(unit):
    """What is wrong with a unit, one line each."""
    said = []
    if unit.get("killed"):
        said.append(f"killed: {unit['killed']}")
    if "exit" in unit and not unit.get("ends"):
        said.append(f"the process ended (status {unit['exit']})")
    for text in unit.get("caught", []):
        said.append(f"caught by the run loop: {text}")
    for text in unit.get("notices", []):
        said.append(f"notice: {text}")
    for seconds in unit.get("hangs", []):
        said.append(f"the main thread stopped {seconds} s")
    return said


def explained(unit, text, rules):
    for rule in rules:
        if re.search(rule.get("unit", ".*"), unit.get("name", "")) and re.search(rule.get("text", ".*"), text):
            return rule.get("why", "explained")
    return None


def notice(kind, title, text):
    text = text.replace("\n", " ").replace("%", "%25")
    print(f"::{kind} title={title}::{text[:1800]}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--state", default="default")
    parser.add_argument("--port", type=int, default=18310)
    parser.add_argument("--explained", default=os.path.join(ROOT, "scripts", "sweep_explained.json"))
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rules = []
    if os.path.exists(args.explained):
        with open(args.explained) as handle:
            rules = json.load(handle)

    proxy_log = open(os.path.join(args.out, "proxy.txt"), "w")
    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "selftest_proxy.py"),
                              "--http", str(args.port), "--socks", str(args.port + 1)], stdout=proxy_log, stderr=subprocess.STDOUT)
    try:
        if not (wait_for_port(args.port) and wait_for_port(args.port + 1)):
            notice("error", f"sweep {args.state}", "the self-test proxy did not start")
            return 1
        environment = dict(os.environ, PB_SELFTEST_HTTP_PROXY_PORT=str(args.port),
                           PB_SELFTEST_SOCKS_PROXY_PORT=str(args.port + 1), PRIVACYBROWSER_LANG=os.environ.get("PRIVACYBROWSER_LANG", ""))
        if not environment["PRIVACYBROWSER_LANG"]:
            del environment["PRIVACYBROWSER_LANG"]
        since = time.time() - 2
        with open(os.path.join(args.out, "stderr.txt"), "w") as log:
            lines, status, stacks = run([os.path.join(args.app, "Contents", "MacOS", "Lumen"), "--sweep"], environment, args.out, log)
    finally:
        proxy.terminate()
    with open(os.path.join(args.out, "sweep.txt"), "w") as handle:
        handle.writelines(lines)

    units, afters, listing = [], {}, None
    for line in lines:
        if line.startswith("SWEEP {"):
            units.append(json.loads(line[len("SWEEP "):]))
        elif line.startswith("SWEEP-AFTER "):
            fields = json.loads(line[len("SWEEP-AFTER "):])
            afters[(fields.get("index"), fields.get("sub"))] = fields
        elif line.startswith("SWEEP-LIST ") and listing is None:
            listing = json.loads(line[len("SWEEP-LIST "):])
    for unit in units:
        after = afters.get((unit.get("index"), unit.get("sub")))
        if after:
            for key in ("caught", "notices", "hangs", "thrown"):
                unit[key] = unit.get(key, []) + [f"(on the way back) {t}" if isinstance(t, str) else t for t in after.get(key, [])]
        stack = stacks.get(str(unit.get("index")))
        if stack and unit.get("hangs"):
            unit["stacks"] = stack
    with open(os.path.join(args.out, "units.json"), "w") as handle:
        json.dump({"state": args.state, "list": listing, "units": units}, handle, ensure_ascii=False, indent=1)
    crashes = crash_reports(since, args.out)
    exception_log(since, args.out)

    done = any("the sweep got to its end" in line for line in lines)
    report = [f"## Sweep — {args.state}", ""]
    if listing:
        report.append(f"Route: {listing.get('route')}; input source {listing.get('inputSource')}; "
                      f"interface {listing.get('language')}, Safari's chrome {listing.get('chrome')}; {len(units)} units.")
        report.append("")
    for line in lines:
        if line.startswith("SWEEP-INFO macOS") or line.startswith("SWEEP-ERROR"):
            report.append(f"- {line.strip()}")
    report.append(f"- the sweep {'got' if done else 'did NOT get'} to its end (exit {status})")
    report += ["", "| Unit | Finding | Explained | First frames |", "|---|---|---|---|"]
    unexplained = 0
    for unit in units:
        thrown = unit.get("thrown", [])
        frames = (thrown[0].split(" | ", 1)[1][:400] if thrown and " | " in thrown[0] else "")
        for text in findings(unit):
            why = explained(unit, text, rules)
            if why is None:
                unexplained += 1
                notice("error", f"sweep {args.state} - {unit.get('name', '?')[:80]}", f"{text} | thrown: {'; '.join(thrown)[:900]}")
            report.append(f"| {unit.get('name', '?').replace('|', '/')} | {text.replace('|', '/')[:300]} | {why or '**no**'} "
                          f"| {frames.replace('|', '/')} |")
    report += ["", "Not as expected:", ""]
    for unit in units:
        for text in unit.get("failed", []):
            report.append(f"- {unit.get('name', '?')}: {text[:300]}")
            notice("warning", f"sweep {args.state} - not as expected", f"{unit.get('name', '?')}: {text}")
    report += ["", "Exceptions thrown (caught or not), by unit:", ""]
    for unit in units:
        for text in unit.get("thrown", [])[:3]:
            report.append(f"- {unit.get('name', '?')}: {text[:500]}")
    if crashes:
        report += ["", "Crash reports:", ""]
        for name, summary in crashes:
            unexplained += 1
            report.append(f"- {name}: " + " / ".join(summary.splitlines()[:6])[:900])
            notice("error", f"sweep {args.state} - crash report", f"{name}: {' / '.join(summary.splitlines()[:8])}")
    text = "\n".join(report) + "\n"
    with open(os.path.join(args.out, "report.md"), "w") as handle:
        handle.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(text)
    print(f"SWEEP-RESULT {args.state}: {len(units)} units, {unexplained} unexplained finding(s), "
          f"{'got to its end' if done else 'did NOT get to its end'}", flush=True)
    return 0 if done and unexplained == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
