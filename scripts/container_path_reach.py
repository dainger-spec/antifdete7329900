#!/usr/bin/env python3
"""Measurement: does a write through a preferences domain named by the path of the real Safari's
container plist reach the real Safari? And where does a domain named by a path land?

The menu walk's run 496 logged every NSUserDefaults write in a profile's process: Safari's own code
writes some ten keys (SearchProviderIdentifier removed, StartPageSections, …) through an instance
whose suite is the absolute path of the real Safari's container plist,
~/Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist. The walk's
file trace saw no write there. This writes the same way — CFPreferencesSetAppValue with that path as
the application, from a process outside any sandbox with CFFIXED_USER_HOME and HOME at a profile-like
home, as a profile's process is — a canary home page and a marker, then:

  * whether the container's plist file holds the marker, and whether `defaults read com.apple.Safari`
    (which reads Safari's container) answers it;
  * launches the real Safari: does a new window load the canary? (control: the same kind of canary
    in Safari's argument domain loads.)

And for SafariUIState (the morning's question 7), where a domain named by a path lands: written with
a marker under the profile-like home's Library/Preferences (run 496: the account's own domain of the
app got it) and under another folder of that home — in the file at the path, or in the account's
~/Library/Preferences. Prints CONTAINER-PATH lines; writes --out/container-path.json. Fails nothing.
"""
import argparse
import glob
import json
import os
import plistlib
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import safari_prefs_reach as reach  # noqa: E402

MARKER = "PBContainerPathCanary"

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
domain = cfstr(sys.argv[2])
for key, v in json.loads(sys.argv[1]).items():
    CF.CFPreferencesSetAppValue(cfstr(key), value(v), domain)
print("synchronized" if CF.CFPreferencesAppSynchronize(domain) else "not synchronized")
'''


def say(*parts):
    print("CONTAINER-PATH", *parts, flush=True)


def write(values, domain, home):
    """CFPreferencesSetAppValue into `domain`, then CFPreferencesAppSynchronize, from a process
    outside any sandbox with CFFIXED_USER_HOME and HOME at `home`."""
    os.makedirs(home, exist_ok=True)
    env = dict(os.environ, CFFIXED_USER_HOME=home, HOME=home)
    result = subprocess.run([sys.executable, "-I", "-c", WRITER, json.dumps(values), domain], env=env,
                            capture_output=True, text=True, timeout=60)
    return (result.stdout + result.stderr).strip()


def marker_in(path):
    """The marker's value in the plist at `path`, 'no marker', 'absent', or why it could not be read."""
    if not os.path.exists(path):
        return "absent"
    try:
        with open(path, "rb") as handle:
            data = plistlib.load(handle)
    except Exception as exc:  # TCC can refuse Safari's container
        return f"unreadable ({exc.__class__.__name__})"
    return repr(data.get(MARKER)) if MARKER in data else "no marker"


def account_files_with_marker(since):
    """Every plist in the account's ~/Library/Preferences changed since `since` that holds the marker."""
    found = []
    for path in glob.glob(os.path.join(reach.HOME, "Library/Preferences/*.plist")):
        try:
            if os.stat(path).st_mtime < since - 1:
                continue
            with open(path, "rb") as handle:
                data = plistlib.load(handle)
        except Exception:
            continue
        if MARKER in data:
            found.append(f"{os.path.basename(path)}={data[MARKER]!r}")
    return found


def launch(label, server, url_name, notes, args=None):
    """The real Safari launched without a URL — cfprefsd left as it is (reach.launch drops its caches
    first, which could take a write held only there) — and whether a new window loads the canary."""
    since = time.time()
    command = ["open", "-b", "com.apple.Safari"] + (["--args"] + args if args else [])
    opened = reach.sh(command, timeout=60)
    requests = server.wait_for(since, 45)
    how = reach.quit_safari()
    expected = f"/canary-{url_name}"
    loaded = any(r["path"] == expected for r in requests)
    notes[label] = {"command": " ".join(command), "open": opened, "requests": requests, "quit": how, "loaded": loaded}
    say(f"{label}: requests {[r['path'] for r in requests] or 'none'}; {expected} {'LOADED' if loaded else 'not loaded'}; quit: {how}")
    return loaded


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", required=True)
    parsed = parser.parse_args()
    work = os.path.abspath(parsed.out)
    os.makedirs(work, exist_ok=True)
    notes = {"macos": reach.sh(["sw_vers"])[1], "safari": reach.sh(["defaults", "read", "/Applications/Safari.app/Contents/Info.plist",
                                                                    "CFBundleShortVersionString"])[1]}
    say("macOS", notes["macos"].replace("\n", " "), "Safari", notes["safari"])
    server = reach.Server()
    reach.quit_safari()
    home = os.path.join(work, "profile-home")

    # Safari's container, as on a Mac where Safari has run: a first launch makes it.
    if not os.path.isdir(reach.CONTAINER):
        launch("first launch (makes the container)", server, "none", notes)
    say("container:", "there" if os.path.isdir(reach.CONTAINER) else "absent",
        "; its plist:", marker_in(reach.CONTAINER_PLIST))

    # 1. Through the container plist's path, as Safari's code in a profile's process writes.
    since = time.time()
    values = dict(reach.canary(server.url("P")), **{MARKER: "container path"})
    notes["write_container_path"] = write(values, reach.CONTAINER_PLIST, home)
    time.sleep(6)
    seen = {
        "container_plist": marker_in(reach.CONTAINER_PLIST),
        "defaults_read_com.apple.Safari": reach.sh(["defaults", "read", "com.apple.Safari", MARKER])[1][-200:],
        "defaults_read_HomePage": reach.sh(["defaults", "read", "com.apple.Safari", "HomePage"])[1][-200:],
        "account_plists_with_marker": account_files_with_marker(since),
    }
    notes["after_container_path_write"] = seen
    say("write through the container plist's path:", notes["write_container_path"])
    for key, value in seen.items():
        say(f"  {key}: {value}")
    launch("launch P", server, "P", notes)
    say("after launch P: the container's plist:", marker_in(reach.CONTAINER_PLIST))

    # Control: the canary where Safari certainly reads it — its argument domain.
    launch("control", server, "control", notes,
           args=["-HomePage", server.url("control"), "-NewWindowBehavior", "0", "-NewTabBehavior", "0",
                 "-AlwaysRestoreSessionAtLaunch", "NO", "-OpenPrivateWindowWhenNotRestoringSessionAtLaunch", "NO"])

    # 2. Where a domain named by a path lands (SafariUIState).
    variants = [
        ("under the home's Library/Preferences, no .plist", os.path.join(home, "Library/Preferences/dev.local.PrivacyBrowser")),
        ("under the home's Library/Preferences, with .plist", os.path.join(home, "Library/Preferences/dev.local.PrivacyBrowser.plist")),
        ("under another folder of the home, no .plist", os.path.join(home, "Library/PrivacyBrowser/SafariUIState")),
        ("under another folder of the home, with .plist", os.path.join(home, "Library/PrivacyBrowser/SafariUIState.plist")),
    ]
    notes["path_domains"] = {}
    for index, (name, domain) in enumerate(variants):
        os.makedirs(os.path.dirname(domain), exist_ok=True)
        since = time.time()
        mark = f"variant {index}"
        written = write({MARKER: mark}, domain, home)
        time.sleep(4)
        base = domain[:-len(".plist")] if domain.endswith(".plist") else domain
        landed = {
            "the file at the path": marker_in(base + ".plist"),
            "the file at the path as given": marker_in(domain) if domain.endswith(".plist") else "-",
            "the account's ~/Library/Preferences": account_files_with_marker(since) or "none",
        }
        notes["path_domains"][name] = {"domain": domain, "write": written, "landed": landed}
        say(f"path domain {name} ({domain}): {written}; " + "; ".join(f"{k}: {v}" for k, v in landed.items()))

    control = notes["control"]["loaded"]
    p = notes["launch P"]["loaded"]
    verdict = ("inconclusive: the control canary did not load" if not control else
               f"through the container plist's path: Safari's new window {'LOADED' if p else 'did not load'} the canary; "
               f"the container's plist {seen['container_plist']}; defaults read com.apple.Safari {seen['defaults_read_com.apple.Safari']!r}")
    notes["verdict"] = verdict
    say("verdict:", verdict)
    with open(os.path.join(work, "container-path.json"), "w") as handle:
        json.dump(notes, handle, indent=2, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
