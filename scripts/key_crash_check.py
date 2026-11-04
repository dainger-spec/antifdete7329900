#!/usr/bin/env python3
"""A crash report of a process that holds the account's key holds no form of the key.

    python3 scripts/key_crash_check.py path/to/Lumen.app/Contents/MacOS/Lumen

The owner (2 November): the key bought without registration is kept as the master password is —
not in the log, the diagnostics, a crash report, or the automation API. The self-test checks the
log, the diagnostics ZIP and the API's answers (LicenseSelfTest). A crash report is written by the
system after the process is gone, so it is checked here: `Lumen --key-crash-check` signs in with a
key against an account server played on this Mac, keeps the key in a vault, and crashes on purpose
with the key still held; macOS writes its report to ~/Library/Logs/DiagnosticReports, and every form
of the key is looked for in it.

The crash is on a dispatch queue of its own, whose name the report keeps; a fatal error's message is
not in the report (CI run 601). The control, `--key-crash-check --control`, crashes the same way on a
queue named with the key's text: its report must hold the key. A search that cannot find it checks
nothing, so the control runs first and the check fails when the control's report is missing or comes
back clean. With `--save <folder>`, both reports are copied there.
"""
import glob
import os
import re
import shutil
import subprocess
import sys
import time

# Every form the self-test's key can be written in (LicenseSelfTest.keyForms).
KEY_FORMS = ["LMK-0123-4567-89AB-CDEF-GHJK-MNMT", "0123456789ABCDEFGHJKMNMT", "0123456789abcdefghjkmnmt",
             "0123-4567-89AB", "0123-4567-89ab"]
FOLDERS = [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]


def reports():
    found = set()
    for folder in FOLDERS:
        found.update(glob.glob(os.path.join(folder, "**", "*"), recursive=True))
    return {path for path in found if os.path.isfile(path)}


def crash(binary, control):
    """Runs the check once; (pid, path of its crash report, the report's text) — None where missing."""
    before = reports()
    arguments = [binary, "--key-crash-check"] + (["--control"] if control else [])
    try:
        run = subprocess.run(arguments, capture_output=True, text=True, timeout=180)
        output, status = run.stdout + run.stderr, run.returncode
    except subprocess.TimeoutExpired:
        output, status = "the check did not end in 3 minutes", None
    lines = [line for line in output.splitlines() if line.startswith("KEY-CRASH")]
    print("\n".join(lines) or output[-2000:])
    print(f"exit status {status}")
    match = re.search(r"pid (\d+)", "\n".join(lines))
    if not match or not any("crashing on purpose" in line for line in lines):
        return None, None, None
    pid = match.group(1)
    deadline = time.time() + 120
    while time.time() < deadline:
        for path in sorted(reports() - before):
            try:
                with open(path, encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue
            if re.search(r'"pid"\s*:\s*' + pid + r"\b", text) or re.search(r"\[" + pid + r"\]", text):
                return pid, path, text
        time.sleep(2)
    return pid, None, None


def crashed_queue(text):
    """The name of the queue the crashed thread was on, as the report keeps it."""
    names = re.findall(r'"queue"\s*:\s*"([^"]*PBKeyCrashCheck[^"]*)"', text)
    return names[0] if names else "(no PBKeyCrashCheck queue in the report)"


def save(path, folder, name):
    if folder and path:
        os.makedirs(folder, exist_ok=True)
        shutil.copy(path, os.path.join(folder, name))


def main():
    arguments = sys.argv[1:]
    folder = None
    if "--save" in arguments:
        index = arguments.index("--save")
        folder = arguments[index + 1] if index + 1 < len(arguments) else None
        del arguments[index:index + 2]
    if len(arguments) != 1 or not os.access(arguments[0], os.X_OK):
        print(__doc__)
        return 2
    binary = arguments[0]
    failures = 0

    print("::group::the control: the key's text in the crash's message")
    pid, path, text = crash(binary, control=True)
    print("::endgroup::")
    if not path:
        print(f"FAIL the control's crash report was not found (pid {pid}): this Mac cannot show what a crash report holds")
        return 1
    save(path, folder, "control.ips")
    held = [form for form in KEY_FORMS if form in text]
    print(f"the control's report: {path} ({len(text)} characters), the crashed queue: {crashed_queue(text)}")
    if held:
        print(f"PASS the control: its crash report holds the key ({held[0]}) — the search can find it")
    else:
        print("FAIL the control's crash report does not hold the key: the search proves nothing")
        failures += 1

    print("::group::the check: a crash with the key held in memory")
    pid, path, text = crash(binary, control=False)
    print("::endgroup::")
    if not path:
        print(f"FAIL the check's crash report was not found (pid {pid})")
        return 1
    save(path, folder, "check.ips")
    held = [form for form in KEY_FORMS if form in text]
    print(f"the check's report: {path} ({len(text)} characters), the crashed queue: {crashed_queue(text)}")
    if held:
        print(f"FAIL the crash report of a process holding the key holds it: {', '.join(held)}")
        failures += 1
    else:
        print("PASS the crash report of a process holding the key holds no form of it")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
