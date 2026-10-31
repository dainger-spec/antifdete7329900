#!/usr/bin/env python3
"""Measurement: do the com.apple.Safari keys a profile's process wrote before dbea98c reach the
real Safari?

Before dbea98c every profile's launch wrote 15 keys to com.apple.Safari with CFPreferences, from
the profile's own process (not sandboxed, CFFIXED_USER_HOME at the profile's home); cfprefsd put
them in the account's ~/Library/Preferences/com.apple.Safari.plist (menu walk, run 457). The real
Safari is sandboxed and keeps its preferences in its container. This writes the same keys the same
way, with a canary next to them — a home page on a local server, and new windows opening it — and
launches the real Safari:

  A    as the runner has it (its container moved aside first if it can be: then this launch is
       Safari's first, the case of a Mac where it was never opened) — does a new window load the
       canary? are the keys in the container afterwards?
  ctl  the same kind of canary in Safari's argument domain (open --args): the canary works
  B    the container there and used, the write repeated with canary B — where it lands; Safari
       launched again — does canary B load?

While each launch runs, fs_usage records which com.apple.Safari plist files are opened and by
whom (cfprefsd's caches dropped first, so a read of the domain opens its file). Prints
SAFARI-PREFS lines; writes --out/safari-prefs.json. A measurement; it fails nothing.
"""
import argparse
import ctypes
import http.server
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SEND_URL = os.path.join(HERE, "safari_process", "send_url.js")
HOME = os.path.expanduser("~")
HOME_PLIST = os.path.join(HOME, "Library/Preferences/com.apple.Safari.plist")
CONTAINER = os.path.join(HOME, "Library/Containers/com.apple.Safari")
CONTAINER_PLIST = os.path.join(CONTAINER, "Data/Library/Preferences/com.apple.Safari.plist")
SAFARI_PROCESS = r"Safari\.app/Contents/MacOS/Safari( |$)"

# What a profile with a proxy and Safe Browsing off (the default) wrote:
# SafariChrome.servicePreferenceValues before dbea98c.
OURS = {
    "AutoFillPasswords": False,
    "AutoFillCreditCardData": False,
    "AutoFillMiscellaneousForms": False,
    "AutoFillFromAddressBook": False,
    "UniversalSearchEnabled": False,
    "SuppressSearchSuggestions": True,
    "WarnAboutFraudulentWebsites": False,
    "WebKitPreferences.privateClickMeasurementEnabled": False,
    "WebKitDNSPrefetchingEnabled": False,
    "WebKitPreferences.dnsPrefetchingEnabled": False,
    "WebsiteSpecificSearchEnabled": False,
    "PreloadTopHit": False,
    "CanPromptForPushNotifications": False,
    "ExtensionsEnabled": False,
    "AutoOpenSafeDownloads": False,
}
CANARY_KEYS = ["HomePage", "NewWindowBehavior", "NewTabBehavior", "AlwaysRestoreSessionAtLaunch",
               "OpenPrivateWindowWhenNotRestoringSessionAtLaunch"]


def canary(url):
    """A new window opens the home page, and a launch opens a new window rather than restoring."""
    return {"HomePage": url, "NewWindowBehavior": 0, "NewTabBehavior": 0, "AlwaysRestoreSessionAtLaunch": False,
            "OpenPrivateWindowWhenNotRestoringSessionAtLaunch": False}


def say(*parts):
    print("SAFARI-PREFS", *parts, flush=True)


def sh(command, timeout=60):
    try:
        result = subprocess.run(command, shell=isinstance(command, str), capture_output=True, text=True, timeout=timeout)
        return result.returncode, (result.stdout + result.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"


# --- The write, as a profile's process made it --------------------------------------------------

WRITER = r'''
import ctypes, json, sys
CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFNumberCreate.restype = ctypes.c_void_p
CF.CFNumberCreate.argtypes = [ctypes.c_void_p, ctypes.c_long, ctypes.c_void_p]
CF.CFPreferencesSetAppValue.restype = None
CF.CFPreferencesSetAppValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
CF.CFPreferencesAppSynchronize.restype = ctypes.c_ubyte
CF.CFPreferencesAppSynchronize.argtypes = [ctypes.c_void_p]
TRUE = ctypes.c_void_p.in_dll(CF, "kCFBooleanTrue").value
FALSE = ctypes.c_void_p.in_dll(CF, "kCFBooleanFalse").value
def cfstr(s):
    return CF.CFStringCreateWithCString(None, s.encode(), 0x08000100)
def value(v):
    if isinstance(v, bool):
        return TRUE if v else FALSE
    if isinstance(v, int):
        n = ctypes.c_int64(v)
        return CF.CFNumberCreate(None, 4, ctypes.byref(n))
    return cfstr(v)
domain = cfstr("com.apple.Safari")
for key, v in json.loads(sys.argv[1]).items():
    CF.CFPreferencesSetAppValue(cfstr(key), value(v), domain)
print("synchronized" if CF.CFPreferencesAppSynchronize(domain) else "not synchronized")
'''


def write_like_a_profile(values, work):
    """CFPreferencesSetAppValue into com.apple.Safari, then CFPreferencesAppSynchronize, from a
    process outside any sandbox with CFFIXED_USER_HOME (and HOME) at a profile-like home."""
    fake_home = os.path.join(work, "profile-home")
    os.makedirs(fake_home, exist_ok=True)
    env = dict(os.environ, CFFIXED_USER_HOME=fake_home, HOME=fake_home)
    result = subprocess.run([sys.executable, "-I", "-c", WRITER, json.dumps(values)], env=env,
                            capture_output=True, text=True, timeout=60)
    found = [os.path.relpath(os.path.join(d, f), fake_home) for d, _, fs in os.walk(fake_home) for f in fs]
    return {"exit": result.returncode, "output": (result.stdout + result.stderr).strip(), "files_in_profile_home": found}


# --- What is where -------------------------------------------------------------------------------

def read_plist(path, keys):
    """The values of `keys` in the plist at `path`, or why it could not be read."""
    try:
        stat = os.stat(path)
    except FileNotFoundError:
        return {"exists": False}
    except OSError as exc:
        return {"exists": "?", "error": f"stat: {exc}"}
    info = {"exists": True, "mtime": stat.st_mtime, "size": stat.st_size}
    try:
        with open(path, "rb") as handle:
            data = plistlib.load(handle)
    except Exception as exc:  # TCC refuses Safari's container to some processes
        info["error"] = f"read: {exc}"
        return info
    info["keys"] = len(data)
    info["values"] = {key: data[key] for key in keys if key in data}
    return info


def snapshot(label, notes):
    keys = list(OURS) + CANARY_KEYS
    state = {"home_plist": read_plist(HOME_PLIST, keys), "container_exists": os.path.isdir(CONTAINER),
             "container_plist": read_plist(CONTAINER_PLIST, keys),
             "defaults_HomePage": sh(["defaults", "read", "com.apple.Safari", "HomePage"])[1][-300:]}
    notes[label] = state
    say(f"{label}: home plist {describe(state['home_plist'])}")
    say(f"{label}: container", describe(state["container_plist"]) if state["container_exists"] else "absent")
    say(f"{label}: defaults read com.apple.Safari HomePage -> {state['defaults_HomePage'][:200]!r}")
    return state


def describe(plist):
    """How many of our keys a plist holds with the value a profile wrote, and its canary."""
    if not plist.get("exists"):
        return "absent"
    if "values" not in plist:
        return plist.get("error", "?")
    values = plist["values"]
    same = [key for key, value in OURS.items() if key in values and values[key] == value]
    other = {key: values[key] for key in OURS if key in values and values[key] != OURS[key]}
    return (f"{plist['keys']} keys; ours with our value {len(same)}/15, ours with another value {other or 'none'}; "
            f"canary {({key: values[key] for key in CANARY_KEYS if key in values}) or 'none'}")


# --- The canary server ---------------------------------------------------------------------------

class Server:
    def __init__(self):
        self.requests = []
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.requests.append({"time": time.time(), "path": self.path,
                                       "agent": self.headers.get("User-Agent", "")})
                body = f"<!doctype html><title>canary {self.path}</title><p>{self.path}".encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def url(self, name):
        return f"http://127.0.0.1:{self.port}/canary-{name}"

    def wait_for(self, since, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            seen = [r for r in self.requests if r["time"] >= since]
            if seen:
                time.sleep(2)
                return [r for r in self.requests if r["time"] >= since]
            time.sleep(0.5)
        return []


# --- Safari --------------------------------------------------------------------------------------

def safari_pids():
    code, output = sh(["pgrep", "-f", SAFARI_PROCESS])
    return [int(p) for p in output.split()] if code == 0 else []


def quit_safari():
    for pid in safari_pids():
        sh(["osascript", "-l", "JavaScript", SEND_URL, str(pid), "--quit"], timeout=30)
    for _ in range(30):
        if not safari_pids():
            return "quit"
        time.sleep(0.5)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in safari_pids():
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
        time.sleep(3)
    return "ended" if not safari_pids() else f"still running: {safari_pids()}"


class Watch:
    """fs_usage and cfprefsd's log while Safari runs, after cfprefsd's caches are dropped."""

    def __init__(self, work, label):
        self.fs_path = os.path.join(work, f"fs_usage-{label}.txt")
        self.log_path = os.path.join(work, f"log-{label}.txt")
        sh("killall cfprefsd")
        time.sleep(1)
        self.fs = subprocess.Popen(["sudo", "-n", "fs_usage", "-w", "-f", "filesys"],
                                   stdout=open(self.fs_path, "w"), stderr=subprocess.STDOUT)
        self.log = subprocess.Popen(["log", "stream", "--level", "debug", "--style", "compact", "--predicate",
                                     'process == "cfprefsd" OR subsystem == "com.apple.defaults"'],
                                    stdout=open(self.log_path, "w"), stderr=subprocess.STDOUT)
        time.sleep(2)

    def stop(self):
        sh("sudo -n pkill -INT -x fs_usage")
        self.log.terminate()
        for process in (self.fs, self.log):
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
        opens = {}
        with open(self.fs_path, errors="replace") as handle:
            for line in handle:
                if "com.apple.Safari.plist" not in line:
                    continue
                path = re.search(r"(/\S*com\.apple\.Safari\.plist\S*)", line)
                fields = line.split()
                key = (fields[1] if len(fields) > 1 else "?", path.group(1) if path else "?", fields[-1] if fields else "?")
                opens[key] = opens.get(key, 0) + 1
        with open(self.log_path, errors="replace") as handle:
            lines = [line.rstrip() for line in handle if "com.apple.Safari" in line and "WebApp" not in line]
        return {"plist_events": [{"call": c, "path": p, "process": who, "count": n} for (c, p, who), n in sorted(opens.items())],
                "cfprefsd_log": lines[:60]}


def launch(label, server, url_name, work, notes, args=None):
    """Launches the real Safari without a URL; what it loads, and what was read meanwhile."""
    watch = Watch(work, label)
    since = time.time()
    command = ["open", "-b", "com.apple.Safari"] + (["--args"] + args if args else [])
    opened = sh(command, timeout=60)
    requests = server.wait_for(since, 45)
    windows = sh(["osascript", "-e", 'tell application "System Events" to get name of every window of process "Safari"'], timeout=30)
    pids = safari_pids()
    quit_how = quit_safari()
    seen = watch.stop()
    expected = f"/canary-{url_name}"
    loaded = any(r["path"] == expected for r in requests)
    result = {"command": " ".join(command), "open": opened, "pids": pids, "requests": requests,
              "windows": windows, "quit": quit_how, "expected": expected, "loaded": loaded, **seen}
    notes[label] = result
    say(f"{label}: launched {'(' + ' '.join(args) + ') ' if args else ''}pids {pids}; requests "
        f"{[r['path'] for r in requests] or 'none'}; {expected} {'LOADED' if loaded else 'not loaded'}; "
        f"windows {windows[1][:160]!r}; quit: {quit_how}")
    for event in seen["plist_events"]:
        say(f"{label}:   {event['process']} {event['call']} {event['path']} x{event['count']}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", required=True)
    parsed = parser.parse_args()
    work = os.path.abspath(parsed.out)
    os.makedirs(work, exist_ok=True)
    notes = {"macos": sh(["sw_vers"])[1], "safari": sh(["defaults", "read", "/Applications/Safari.app/Contents/Info.plist",
                                                        "CFBundleShortVersionString"])[1]}
    say("macOS", notes["macos"].replace("\n", " "), "Safari", notes["safari"])
    server = Server()
    quit_safari()

    snapshot("start", notes)
    # Safari's first launch on a Mac where it was never opened: its container moved aside, if it can be.
    if os.path.isdir(CONTAINER):
        aside = CONTAINER + ".measure-aside"
        moved = sh(["mv", CONTAINER, aside])
        if moved[0] != 0:
            moved = sh(["sudo", "-n", "mv", CONTAINER, aside])
        notes["container_moved_aside"] = moved
        say("container moved aside:", "yes" if moved[0] == 0 else f"no ({moved[1][:200]})")

    # A: the write as a profile made it, then the real Safari.
    values = dict(OURS, **canary(server.url("A")))
    notes["write_A"] = write_like_a_profile(values, work)
    say("write A:", notes["write_A"]["output"], "files in the profile's home:", notes["write_A"]["files_in_profile_home"])
    snapshot("after write A", notes)
    launch("launch A", server, "A", work, notes)
    snapshot("after launch A", notes)

    # Control: the canary where Safari certainly reads it — its argument domain.
    launch("control", server, "control", work, notes,
           args=["-HomePage", server.url("control"), "-NewWindowBehavior", "0", "-NewTabBehavior", "0",
                 "-AlwaysRestoreSessionAtLaunch", "NO", "-OpenPrivateWindowWhenNotRestoringSessionAtLaunch", "NO"])
    snapshot("after control", notes)

    # B: Safari's container there and used; the write repeated, then Safari again.
    values = dict(OURS, **canary(server.url("B")))
    notes["write_B"] = write_like_a_profile(values, work)
    say("write B:", notes["write_B"]["output"])
    snapshot("after write B", notes)
    launch("launch B", server, "B", work, notes)
    snapshot("after launch B", notes)

    moved = "container_moved_aside" in notes and notes["container_moved_aside"][0] == 0
    first = moved or not notes["start"]["container_exists"]
    a, control, b = notes["launch A"]["loaded"], notes["control"]["loaded"], notes["launch B"]["loaded"]
    after_a = notes["after launch A"]["container_plist"]
    migrated = [key for key, value in OURS.items() if after_a.get("values", {}).get(key) == value]
    if "values" not in after_a:
        migrated = f"not read ({after_a.get('error', 'no plist') if after_a.get('exists') else 'no plist'})"
    elif after_a["values"].get("HomePage") == server.url("A"):
        migrated = f"{len(migrated)}/15, canary A too"
    else:
        migrated = f"{len(migrated)}/15, not canary A"
    if not control:
        verdict = "inconclusive: the control canary did not load, so a canary not loading says nothing"
    else:
        verdict = (f"launch A ({'Safari first launched, its container new' if first else 'its container as the runner had it'}): "
                   f"canary {'LOADED' if a else 'not loaded'}, our keys with our values in the container after it: "
                   f"{migrated}; launch B (container in use): canary {'LOADED' if b else 'not loaded'}")
    notes["verdict"] = verdict
    say("verdict:", verdict)

    if os.path.exists(HOME_PLIST):
        os.remove(HOME_PLIST)
    with open(os.path.join(work, "safari-prefs.json"), "w") as handle:
        json.dump(notes, handle, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
