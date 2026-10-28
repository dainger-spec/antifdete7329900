#!/usr/bin/env python3
"""Prototype: Safari's own code as one process per profile, each with its own data
(docs/SAFARI_PROCESS.md). macOS 14+.

The `Safari` executable itself cannot do this: it is sandboxed, and its data always lands in its
one container (~/Library/Containers/com.apple.Safari), whatever HOME or launch method is used.
Apple ships two siblings that can, and this script drives both:

  dev     SafariForWebKitDevelopment, the second executable inside Safari.app (Apple-signed; WebKit's
          run-safari uses it). It runs Safari's full UI (windows, tabs, address bar) without the App
          Sandbox, so CFFIXED_USER_HOME decides where its data goes: website data in
          <profile>/Library/WebKit/SafariForWebKitDevelopment/, Safari's own files under
          <profile>/Library/Safari. Cookies are the exception: their file follows the account's real
          home, so in a profile folder they last only until the process quits (on the runners:
          macOS 14, 15, 26). It has none of Safari's entitlements: no Apple Pay or Web Push that
          works, no iCloud, no Safari passwords from the Keychain. WebKit's per-process proxy
          defaults (-WebKit2HTTPProxy / -WebKit2HTTPSProxy, HTTP CONNECT proxies only) apply to it.

  webapp  A Safari web app (File > Add to Dock): Apple's "Web App" host from the Safari cryptex, with
          Safari's entitlements, its own process and its own website data, but one site per app and
          no address bar. There is no API to create one, so `webapp-create` drives Safari's menu
          through System Events (the terminal needs Accessibility and Automation permission).

    safari_profile.py dev-launch --profile ~/Profiles/work [--https-proxy http://127.0.0.1:3128] [URL]
    safari_profile.py dev-open   --profile ~/Profiles/work URL
    safari_profile.py dev-quit   --profile ~/Profiles/work
    safari_profile.py webapp-create NAME URL
    safari_profile.py webapp-launch NAME
    safari_profile.py list --profiles ~/Profiles

URLs reach a running `dev` profile through a GURL Apple Event addressed to its PID (all of them
share Safari's bundle identifier, so they cannot be told apart by name); the first use asks for
Automation permission. Quitting goes the same way, so cookies are written before the process ends.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SAFARI_APP = "/Applications/Safari.app"
SAFARI_DEV_BIN = SAFARI_APP + "/Contents/MacOS/SafariForWebKitDevelopment"
PID_FILE = ".safari-profile.json"


def _osascript(*args, timeout=30):
    result = subprocess.run(["osascript", *args], capture_output=True, text=True, timeout=timeout)
    return result.returncode, (result.stdout + result.stderr).strip()


def send_url(pid, url):
    """Opens `url` in the process `pid` (GURL Apple Event); "--quit" asks it to quit instead."""
    return _osascript("-l", "JavaScript", os.path.join(HERE, "send_url.js"), str(pid), url)


def proxy_arguments(http_proxy=None, https_proxy=None):
    """WebKit reads these user defaults when the host is Safari (com.apple.Safari*), so as launch
    arguments (the argument domain) they set a proxy for this process only. HTTP CONNECT proxies,
    written as URLs: http://host:port."""
    args = []
    if http_proxy:
        args += ["-WebKit2HTTPProxy", http_proxy]
    if https_proxy:
        args += ["-WebKit2HTTPSProxy", https_proxy]
    return args


# ---------------------------------------------------------------------------------------------
# dev: SafariForWebKitDevelopment with a home of its own


def _state(profile):
    try:
        with open(os.path.join(profile, PID_FILE)) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def dev_pid(profile):
    """The PID of this profile's running process, or None."""
    pid = _state(profile).get("pid")
    if not pid:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return pid if "SafariForWebKitDevelopment" in result.stdout else None


def dev_launch(profile, url=None, http_proxy=None, https_proxy=None, binary=SAFARI_DEV_BIN, settle=6):
    """Starts Safari's UI for `profile` (a folder; created if missing) and opens `url` in it.
    Returns (pid, popen or None). A profile already running only gets the URL."""
    profile = os.path.abspath(os.path.expanduser(profile))
    pid = dev_pid(profile)
    if pid:
        state = _state(profile)
        if (http_proxy or https_proxy) and (http_proxy, https_proxy) != (state.get("http_proxy"), state.get("https_proxy")):
            raise RuntimeError(f"profile already running (pid {pid}) with http_proxy={state.get('http_proxy')!r}, "
                               f"https_proxy={state.get('https_proxy')!r}; a proxy is fixed at launch: dev-quit it first")
        if url:
            code, output = send_url(pid, url)
            if code or not output.startswith("sent"):
                raise RuntimeError(f"could not hand it the URL: {output}")
        return pid, None
    if not os.path.exists(binary):
        raise FileNotFoundError(f"{binary} is not on this Mac")
    os.makedirs(os.path.join(profile, "tmp"), exist_ok=True)
    env = dict(os.environ, HOME=profile, CFFIXED_USER_HOME=profile, TMPDIR=os.path.join(profile, "tmp") + "/")
    log = open(os.path.join(profile, "safari.log"), "a")
    process = subprocess.Popen([binary] + proxy_arguments(http_proxy, https_proxy), env=env,
                               stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    with open(os.path.join(profile, PID_FILE), "w") as handle:
        json.dump({"pid": process.pid, "http_proxy": http_proxy, "https_proxy": https_proxy,
                   "started": time.time()}, handle)
    time.sleep(settle)  # until it answers Apple Events
    if process.poll() is not None:
        raise RuntimeError(f"SafariForWebKitDevelopment exited with {process.returncode}; see {log.name}")
    if url:
        for attempt in range(4):  # a slow first launch may not answer Apple Events yet
            code, output = send_url(process.pid, url)
            if not code and output.startswith("sent"):
                break
            time.sleep(3)
        else:
            raise RuntimeError(f"could not hand it the URL: {output}")
    return process.pid, process


def dev_open(profile, url):
    pid = dev_pid(os.path.abspath(os.path.expanduser(profile)))
    if not pid:
        raise RuntimeError("this profile is not running; use dev-launch")
    return send_url(pid, url)


def dev_quit(profile, timeout=15):
    """Asks the profile's process to quit (it saves its cookies on the way out); terminates it after
    `timeout` seconds. Returns None if it was not running, else how it ended."""
    profile = os.path.abspath(os.path.expanduser(profile))
    pid = dev_pid(profile)
    if not pid:
        return None
    code, answer = send_url(pid, "--quit")
    deadline = time.time() + timeout
    while time.time() < deadline and dev_pid(profile):
        time.sleep(0.5)
    if dev_pid(profile):
        os.kill(pid, 15)
        return f"terminated after {timeout} s (quit event: {answer})"
    return "quit"


# ---------------------------------------------------------------------------------------------
# webapp: Safari web apps


def webapp_bundle(name):
    return os.path.expanduser(f"~/Applications/{name}.app")


def webapp_create(name, url, wait=30):
    """Opens `url` in Safari and adds it to the Dock as a web app called `name` (File > Add to Dock).
    Safari copies the site's cookies into the new app; nothing else is shared afterwards.
    Returns the bundle's path."""
    subprocess.run(["open", "-b", "com.apple.Safari", url], check=True, timeout=30)
    time.sleep(5)
    code, output = _osascript(os.path.join(HERE, "add_to_dock.applescript"), name, timeout=60)
    if code:
        raise RuntimeError(f"Add to Dock failed: {output}")
    bundle = webapp_bundle(name)
    deadline = time.time() + wait
    while time.time() < deadline and not os.path.exists(os.path.join(bundle, "Contents", "Info.plist")):
        time.sleep(1)
    if not os.path.exists(bundle):
        raise RuntimeError(f"Safari did not create {bundle}")
    return bundle


def webapp_launch(name, args=None):
    bundle = webapp_bundle(name)
    if not os.path.exists(bundle):
        raise FileNotFoundError(bundle)
    subprocess.run(["open", bundle] + (["--args"] + args if args else []), check=True, timeout=30)
    return bundle


def webapp_identifier(name):
    result = subprocess.run(["plutil", "-extract", "CFBundleIdentifier", "raw",
                             os.path.join(webapp_bundle(name), "Contents", "Info.plist")],
                            capture_output=True, text=True)
    return result.stdout.strip()


# ---------------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    launch = sub.add_parser("dev-launch", help="start Safari's UI for a profile folder")
    launch.add_argument("--profile", required=True)
    launch.add_argument("--http-proxy", help="http://host:port (HTTP CONNECT proxy) for http:// loads")
    launch.add_argument("--https-proxy", help="http://host:port (HTTP CONNECT proxy) for https:// loads")
    launch.add_argument("url", nargs="?")
    opener = sub.add_parser("dev-open", help="open a URL in a running profile")
    opener.add_argument("--profile", required=True)
    opener.add_argument("url")
    quitter = sub.add_parser("dev-quit", help="quit a running profile")
    quitter.add_argument("--profile", required=True)
    create = sub.add_parser("webapp-create", help="add a site to the Dock as a web app (UI scripting)")
    create.add_argument("name")
    create.add_argument("url")
    run = sub.add_parser("webapp-launch", help="start a web app")
    run.add_argument("name")
    lister = sub.add_parser("list", help="profile folders under a directory, and whether they run")
    lister.add_argument("--profiles", required=True)
    args = parser.parse_args()

    if args.command == "dev-launch":
        pid, process = dev_launch(args.profile, args.url, args.http_proxy, args.https_proxy)
        print(f"profile {args.profile}: {'started' if process else 'already running'}, pid {pid}")
    elif args.command == "dev-open":
        print(dev_open(args.profile, args.url)[1])
    elif args.command == "dev-quit":
        print(dev_quit(args.profile) or "not running")
    elif args.command == "webapp-create":
        bundle = webapp_create(args.name, args.url)
        print(f"{bundle} ({webapp_identifier(args.name)})")
    elif args.command == "webapp-launch":
        print(webapp_launch(args.name))
    elif args.command == "list":
        root = os.path.expanduser(args.profiles)
        for name in sorted(os.listdir(root)):
            folder = os.path.join(root, name)
            if os.path.isdir(folder):
                pid = dev_pid(folder)
                print(f"{name}\t{'running, pid ' + str(pid) if pid else 'stopped'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
