#!/usr/bin/env python3
"""Drives the system browser framework window probe (docs/SAFARI_FRAMEWORK_PATH.md). macOS only.

    python3 scripts/safari_framework/run_probe.py --app build/unsandboxed/PrivacyBrowser.app \\
        --out build/safari-framework/unsandboxed

Each step is `PrivacyBrowser --safari-probe <step>` in its own process. Reaching into a framework
built for another application crashes rather than returns, so a step that dies takes only itself
down: this records the signal, the crash report and the system log around it, and runs the next
one. Report-only — the exit status is 0 unless the driver itself breaks.
"""
import argparse
import datetime
import glob
import json
import os
import shutil
import subprocess
import sys
import time

STEPS = [
    "image",            # which path opens, and what dyld then lists
    "classes",          # every class the framework's image contributes
    "selectors",        # which class owns the window-creation selectors
    "appcontroller",    # the application controller's methods and ivars
    "windowcontroller", # the window controller's methods, ivars, properties
    "documentcontroller", # the document controller the window path goes through
    "documentcontroller-create", # what happens when AppKit made one of its own first
    "webconfig",        # the framework's web view configuration factory, on its own
    "shared",           # obtaining the application controller instance
    "create-direct",    # allocating the window controller directly
    "create",           # the application-controller window path
    "create-bootstrap", # the same, after the launch callbacks
    "window",           # the whole path as the app runs it, data store included
    "popupfield",       # the popup's own address field against the one that raises in layout
    "popup",            # initAsPopupWindow:YES
    "popup-nofield",    # the same, with the popup's address field turned off before it loads
    "popup-mode",       # initWithBrowsingMode:0 isPopupWindow:YES
    "popup-hidden",     # +hiddenEmptyBrowserWindowControllerWithBrowsingMode:profileIdentifier:isPopupWindow:
    "popup:crash-off",  # popup again, with NSApplicationCrashOnExceptions set to NO rather than unset
    "window:chrome",    # the whole path as -safari-chrome runs it: the popups, then the ordinary window
]

# Run as the app runs them, without NSApplicationCrashOnExceptions: whether an exception raised
# inside the framework can be caught is what these measure, and that setting would end the
# process first. They record each exception as it is raised, so a hang still says why.
AS_THE_APP_RUNS = {"popup", "popup-nofield", "popup-mode", "popup-hidden"}

# "<step>:<variant>" runs a step again under other launch arguments, into its own folder.
VARIANT_ARGUMENTS = {
    # Set, not merely absent: whether AppKit tells the two apart is what it measures.
    "crash-off": ["-NSApplicationCrashOnExceptions", "NO"],
    # As the app runs with the launch argument. Last, because the defaults system would read
    # whatever followed it as its value.
    "chrome": ["-NSApplicationCrashOnExceptions", "NO", "-safari-chrome"],
}

CRASH_DIRS = [
    os.path.expanduser("~/Library/Logs/DiagnosticReports"),
    "/Library/Logs/DiagnosticReports",
]

SIGNAL_NAMES = {
    4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV",
}


def crash_snapshot():
    found = set()
    for directory in CRASH_DIRS:
        found.update(glob.glob(os.path.join(directory, "*.ips")))
    return found


def crash_pid(path):
    """The process a crash report is about. Reports are written late, sometimes after the next
    step has begun, so they are matched to steps by this rather than by when they appeared."""
    try:
        with open(path, "r", errors="replace") as handle:
            body = handle.read().split("\n", 1)[1]
        return json.loads(body).get("pid")
    except (OSError, IndexError, ValueError):
        return None


def attach_crashes(result, candidates):
    """Copies the reports among `candidates` that are about this step's process into its folder."""
    for path in sorted(candidates):
        if "PrivacyBrowser" not in os.path.basename(path) or crash_pid(path) != result["pid"]:
            continue
        if any(crash["path"] == path for crash in result["crashes"]):
            continue
        shutil.copy(path, os.path.join(result["dir"], os.path.basename(path)))
        result["crashes"].append(read_crash(path))


def write_result(result):
    with open(os.path.join(result["dir"], "result.json"), "w") as handle:
        json.dump({key: value for key, value in result.items() if key not in ("output", "log", "dir")}, handle, indent=2)


def read_crash(path):
    """The interesting fields of an .ips report: a JSON header line, then a JSON body."""
    try:
        with open(path, "r", errors="replace") as handle:
            text = handle.read()
    except OSError as error:
        return {"path": path, "error": str(error)}
    parts = text.split("\n", 1)
    summary = {"path": path}
    try:
        summary["header"] = json.loads(parts[0])
    except (ValueError, IndexError):
        summary["header"] = {}
    try:
        body = json.loads(parts[1]) if len(parts) > 1 else {}
    except ValueError:
        summary["body_unparsed"] = text[:4000]
        return summary
    for key in ("exception", "termination", "asi", "vmRegionInfo", "isCorpse", "faultingThread"):
        if key in body:
            summary[key] = body[key]
    frames = []
    images = body.get("usedImages", [])
    for thread in body.get("threads", []):
        if not thread.get("triggered"):
            continue
        for frame in thread.get("frames", [])[:24]:
            index = frame.get("imageIndex")
            name = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
            frames.append("%s + %s" % (name, frame.get("imageOffset")))
    summary["triggered_frames"] = frames
    return summary


def system_log(since, process):
    """Everything the system said about the process in this step's window: AMFI, sandbox, dyld."""
    predicate = ('process == "%s" OR eventMessage CONTAINS[c] "%s" '
                 'OR eventMessage CONTAINS[c] "AMFI" OR eventMessage CONTAINS[c] "Sandbox" '
                 'OR eventMessage CONTAINS[c] "library validation"' % (process, process))
    command = ["log", "show", "--style", "compact", "--start", since, "--predicate", predicate]
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=120)
        return done.stdout
    except (OSError, subprocess.SubprocessError) as error:
        return "log show failed: %s" % error


def run_step(binary, spec, out_dir, timeout):
    step, _, variant = spec.partition(":")
    step_dir = os.path.join(out_dir, spec.replace(":", "-"))
    os.makedirs(step_dir, exist_ok=True)
    before = crash_snapshot()
    # `log show --start` wants local time, and wants to be a little earlier than the step.
    since = (datetime.datetime.now() - datetime.timedelta(seconds=5)).strftime("%Y-%m-%d %H:%M:%S")
    # -NSApplicationCrashOnExceptions on the command line as well as in code: AppKit otherwise
    # swallows an exception raised under its run loop, and the step hangs with nothing to read.
    command = [binary, "--safari-probe", step, "--out", step_dir]
    if variant:
        command += VARIANT_ARGUMENTS[variant]
    elif step not in AS_THE_APP_RUNS:
        command += ["-NSApplicationCrashOnExceptions", "YES"]
    start = time.time()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        status = process.returncode
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        status = None
    output = (stdout or "") + (stderr or "")
    elapsed = time.time() - start

    result = {"step": spec, "pid": process.pid, "seconds": round(elapsed, 1), "exit": status,
              "output": output, "dir": step_dir, "crashes": []}
    if status is None:
        result["outcome"] = "timed out after %d s" % timeout
    elif status < 0:
        result["outcome"] = "killed by %s" % SIGNAL_NAMES.get(-status, "signal %d" % -status)
    elif status == 0:
        result["outcome"] = "exited 0"
    else:
        result["outcome"] = "exited %d" % status

    # A crash leaves its report a moment later. The steps run as the app runs them keep the log
    # even when they exit cleanly: it is where AppKit says what it did with an exception it caught.
    if status is None or status != 0:
        time.sleep(8)
        attach_crashes(result, crash_snapshot() - before)
    if status is None or status != 0 or step in AS_THE_APP_RUNS or variant:
        result["log"] = system_log(since, "PrivacyBrowser")

    with open(os.path.join(step_dir, "output.txt"), "w") as handle:
        handle.write(output)
    if result.get("log"):
        with open(os.path.join(step_dir, "system-log.txt"), "w") as handle:
            handle.write(result["log"])
    write_result(result)
    return result


def crash_reason(result):
    """One line naming why the step died, from the crash report rather than from the signal."""
    for crash in result.get("crashes", []):
        termination = crash.get("termination") or {}
        exception = crash.get("exception") or {}
        pieces = []
        if termination.get("namespace"):
            pieces.append("%s %s" % (termination["namespace"], termination.get("code", "")))
        if termination.get("indicator"):
            pieces.append(termination["indicator"])
        if exception.get("type"):
            pieces.append("%s%s" % (exception["type"], " " + exception["signal"] if exception.get("signal") else ""))
        reasons = (crash.get("asi") or {}).values()
        for reason in reasons:
            pieces.extend(reason if isinstance(reason, list) else [str(reason)])
        if pieces:
            return " / ".join(str(piece).strip() for piece in pieces if str(piece).strip())
    return ""


def headline(result):
    """Why the step ended, in one line: the crash report, else the first exception raised, else
    the result the step printed."""
    reason = crash_reason(result)
    if reason:
        return reason
    raised = result_line = ""
    for line in result["output"].splitlines():
        text = line.strip()
        if not raised and "RAISED" in text:
            raised = text.split("RAISED", 1)[1].strip(" ,:")
        if text.startswith("PROBE RESULT"):
            result_line = text[len("PROBE RESULT"):].strip()
    return "; ".join(piece for piece in (raised and "raised " + raised, result_line) if piece)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="path to PrivacyBrowser.app")
    parser.add_argument("--out", required=True, help="where the per-step output goes")
    parser.add_argument("--steps", nargs="*", default=STEPS, help="which steps to run (default: all)")
    parser.add_argument("--timeout", type=int, default=120, help="seconds a step may take")
    arguments = parser.parse_args()

    binary = os.path.join(arguments.app, "Contents", "MacOS", "PrivacyBrowser")
    if not os.path.exists(binary):
        print("error: no executable at %s" % binary, file=sys.stderr)
        return 2
    os.makedirs(arguments.out, exist_ok=True)

    facts = {}
    for name, command in (("macos", ["sw_vers", "-productVersion"]),
                          ("build", ["sw_vers", "-buildVersion"]),
                          ("sip", ["csrutil", "status"]),
                          ("sdk", ["xcrun", "--show-sdk-version"]),
                          ("xcode", ["xcodebuild", "-version"]),
                          ("arch", ["uname", "-m"])):
        try:
            facts[name] = subprocess.run(command, capture_output=True, text=True, timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError) as error:
            facts[name] = "unavailable: %s" % error
    try:
        facts["signature"] = subprocess.run(["codesign", "-dv", "--entitlements", "-", arguments.app],
                                            capture_output=True, text=True, timeout=60).stderr.strip()
    except (OSError, subprocess.SubprocessError) as error:
        facts["signature"] = "unavailable: %s" % error

    before_run = crash_snapshot()
    results = [run_step(binary, step, arguments.out, arguments.timeout) for step in arguments.steps]
    # Reports still being written when their own step stopped waiting for them.
    unreported = [result for result in results if result["exit"] != 0 and not result["crashes"]]
    if unreported:
        time.sleep(10)
        new = crash_snapshot() - before_run
        for result in unreported:
            attach_crashes(result, new)
            write_result(result)

    lines = ["# Framework window probe", ""]
    lines.append("macOS %s (%s), %s, SIP: %s" % (facts["macos"], facts["build"], facts["arch"],
                                                 facts["sip"].replace("\n", " ")))
    lines.append("built with SDK %s, %s" % (facts["sdk"], facts["xcode"].replace("\n", " ")))
    lines.append("app: %s" % arguments.app)
    lines.append("")
    lines.append("| step | outcome | seconds | why |")
    lines.append("|---|---|---|---|")
    for result in results:
        lines.append("| %s | %s | %s | %s |" % (result["step"], result["outcome"], result["seconds"],
                                                headline(result).replace("|", "/")))
    lines.append("")
    for result in results:
        lines.append("## %s — %s" % (result["step"], result["outcome"]))
        lines.append("")
        lines.append("```")
        lines.append(result["output"].strip()[:20000] or "(no output)")
        lines.append("```")
        lines.append("")
        for crash in result.get("crashes", []):
            lines.append("Crash report `%s`:" % os.path.basename(crash["path"]))
            lines.append("")
            lines.append("```")
            lines.append(json.dumps({key: value for key, value in crash.items() if key != "path"}, indent=2)[:8000])
            lines.append("```")
            lines.append("")

    report = "\n".join(lines)
    with open(os.path.join(arguments.out, "report.md"), "w") as handle:
        handle.write(report)
    with open(os.path.join(arguments.out, "facts.json"), "w") as handle:
        json.dump(facts, handle, indent=2)
    print(report[:40000])

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write("\n## %s — %s\n\n" % (os.path.basename(arguments.out), facts["macos"]))
            handle.write("| step | outcome | why |\n|---|---|---|\n")
            for result in results:
                handle.write("| %s | %s | %s |\n" % (result["step"], result["outcome"],
                                                     headline(result).replace("|", "/")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
