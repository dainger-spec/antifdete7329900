#!/usr/bin/env python3
"""Experiments for docs/SAFARI_PROCESS.md: can the real Safari.app run as a separate process per
profile with its own data, and does its TLS fingerprint stay Safari's? macOS only; CI runs it on
GitHub's macOS runners (.github/workflows/safari-process.yml).

    python3 scripts/safari_process/experiments.py --out build/safari-process --setup-hosts --trust \\
        facts reference baseline webapps open-n env-home exec-home sfwd copy other-user

Every experiment launches one or more browser processes ("instances") at the same page of a local
server (harness.ReportServer, http://127.0.0.1:<port>/run). The page reports what storage it
already sees, writes its own instance's markers (HttpOnly cookie, script cookie, localStorage,
IndexedDB), waits until all instances have written theirs and reports again; then it fetches
https://<instance>.sp-tls.test:<port>, where harness.TLSServer records the ClientHello (JA3/JA4)
and, with --trust, the HTTP/2 preface (Akamai fingerprint). After a quit, each instance is launched
again to see whether its own markers persisted. Nothing drives the page: no WebDriver. Apple
Events are used only to hand a URL to a process started from its executable, and Accessibility
(System Events) only to create the web apps through Safari's File > Add to Dock.

--setup-hosts, --trust and the other-user experiment use sudo (/etc/hosts entries, a throwaway CA
trusted in the System keychain, a throwaway macOS user): meant for disposable CI runners.
"""
import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))
import harness  # noqa: E402

SAFARI_APP = "/Applications/Safari.app"
SAFARI_BIN = SAFARI_APP + "/Contents/MacOS/Safari"
SAFARI_DEV_BIN = SAFARI_APP + "/Contents/MacOS/SafariForWebKitDevelopment"
SAFARI_ID = "com.apple.Safari"
WEB_APP_HOSTS = ["/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices/Web App.app",
                 "/System/Cryptexes/App/System/Library/CoreServices/Web App.app"]
TLS_DOMAIN = "sp-tls.test"
OTHER_USER = "spprobe"
CONSTRAINT_LOG = ("log show --last 3m --style compact --predicate "
                  "'eventMessage CONTAINS[c] \"constraint\" OR eventMessage CONTAINS[c] \"AMFI\" "
                  "OR eventMessage CONTAINS[c] \"restricted entitlement\" OR process == \"amfid\" "
                  "OR eventMessage CONTAINS[c] \"code signature\"' 2>&1 | tail -40")


def sh(command, timeout=60, env=None):
    """Runs a command (a string goes through the shell); returns (exit code, output). Never raises."""
    try:
        result = subprocess.run(command, shell=isinstance(command, str), capture_output=True, text=True,
                                timeout=timeout, env=env)
        return result.returncode, (result.stdout + result.stderr).strip()
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"") + (exc.stderr or b"")
        return 124, f"timeout after {timeout}s: {out.decode(errors='replace') if isinstance(out, bytes) else out}"
    except OSError as exc:
        return 127, str(exc)


def log(text):
    print(text, flush=True)


def web_app_host():
    return next((path for path in WEB_APP_HOSTS if os.path.exists(path)), WEB_APP_HOSTS[0])


# ---------------------------------------------------------------------------------------------
# Facts about this Mac's Safari


def entitlement_keys(path):
    return (f"codesign -d --entitlements - --xml {shlex.quote(path)} 2>/dev/null | plutil -convert json -o - - 2>/dev/null "
            "| python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"\\n\".join(sorted(d)))'")


FACT_COMMANDS = [
    ("macOS", "sw_vers; uname -m"),
    ("SIP", "csrutil status"),
    ("Safari bundle", f"ls -la /Applications | grep -i safari; readlink {SAFARI_APP}; "
                      "ls -la /System/Cryptexes/App/System/Applications/ 2>&1 | head"),
    ("Safari executables", f"ls -la {SAFARI_APP}/Contents/MacOS/"),
    ("Safari version", f"defaults read {SAFARI_APP}/Contents/Info.plist CFBundleShortVersionString; "
                       f"defaults read {SAFARI_APP}/Contents/Info.plist CFBundleVersion; "
                       f"plutil -p {SAFARI_APP}/Contents/Info.plist | grep -i -E 'Identifier\"|MultipleInstances|NSAppleScript'"),
    ("Safari signature", f"codesign -dvvv {SAFARI_APP} 2>&1 | grep -v -E '^(Hash|CandidateCDHash|CDHash)'"),
    ("Safari entitlement keys", entitlement_keys(SAFARI_APP)),
    ("Safari sandbox and container entitlements",
     f"codesign -d --entitlements - --xml {SAFARI_APP} 2>/dev/null | plutil -convert json -o - - 2>/dev/null | "
     "python3 -c 'import json,sys; d=json.load(sys.stdin); "
     "[print(k, \"=\", d[k]) for k in sorted(d) if any(w in k for w in (\"sandbox\", \"container\", \"webpush\", "
     "\"payment\", \"templateapp\", \"networkserviceproxy\"))]'"),
    ("SafariForWebKitDevelopment", f"codesign -dvvv {SAFARI_DEV_BIN} 2>&1 | grep -E 'Identifier|Format|flags|Authority|TeamIdentifier'; "
                                   + entitlement_keys(SAFARI_DEV_BIN) + " | head -60"),
    ("Web App host", "for p in " + " ".join(shlex.quote(p) for p in WEB_APP_HOSTS) +
                     "; do ls -d \"$p\" 2>&1; done; "
                     f"codesign -dvvv {shlex.quote(WEB_APP_HOSTS[0])} 2>&1 | grep -E 'Identifier|flags|Authority|TeamIdentifier'; "
                     f"defaults read {shlex.quote(WEB_APP_HOSTS[0] + '/Contents/Info.plist')} CFBundleShortVersionString 2>&1"),
    ("Entitlements only in Safari (<) / only in Web App (>)",
     f"diff <({entitlement_keys(SAFARI_APP)}) <({entitlement_keys(WEB_APP_HOSTS[0])}) | grep -E '^[<>]'"),
    ("WebKit XPC services", "ls /System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/ 2>&1; "
                            "ls /System/Cryptexes/App/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/ 2>&1"),
    ("Containers (Safari, WebKit, web apps)", "ls ~/Library/Containers 2>&1 | grep -i -E 'safari|webkit|webapp' | head -40"),
    ("Safari container", "ls -la ~/Library/Containers/com.apple.Safari/Data/Library 2>&1 | head -40"),
    ("~/Library/Safari", "ls -la ~/Library/Safari 2>&1 | head -40"),
    ("Safari profiles store", "ls ~/Library/Containers/com.apple.Safari/Data/Library/WebKit 2>&1; "
                              "ls ~/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore 2>&1 | head; "
                              "ls ~/Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles 2>&1 | head"),
    ("safaridriver", "which safaridriver; ls -la ~/Library/WebDriver 2>&1"),
    ("TCC (system)", "sudo -n sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' "
                     "'select service, client, indirect_object_identifier, auth_value from access order by service' 2>&1 | head -80"),
    ("TCC (user)", "sqlite3 ~/Library/Application\\ Support/com.apple.TCC/TCC.db "
                   "'select service, client, indirect_object_identifier, auth_value from access order by service' 2>&1 | head -80"),
    ("Users and sessions", "dscl . list /Users UniqueID | awk '$2 >= 500'; who; launchctl managername"),
]


def facts(out_dir):
    lines = []
    for title, command in FACT_COMMANDS:
        code, output = sh(["/bin/bash", "-c", command], timeout=90)
        lines.append(f"### {title}\n$ {command}\n{output}\n(exit {code})\n")
        log(f"::group::fact: {title}\n{output}\n::endgroup::")
    with open(os.path.join(out_dir, "facts.txt"), "w") as handle:
        handle.write("\n".join(lines))
    for name, path in [("safari", SAFARI_APP), ("safari-dev", SAFARI_DEV_BIN), ("web-app-host", web_app_host())]:
        code, xml = sh(f"codesign -d --entitlements - --xml {shlex.quote(path)} 2>/dev/null | plutil -convert xml1 -o - -")
        with open(os.path.join(out_dir, f"entitlements-{name}.plist"), "w") as handle:
            handle.write(xml)


# ---------------------------------------------------------------------------------------------
# Processes


PROCESS_PATTERN = "Safari|WebKit|Web App|WebApp|safaridriver|SafariCopy"


def processes():
    code, output = sh(f"ps -axww -o pid,ppid,user,etime,command | grep -E '{PROCESS_PATTERN}' "
                      "| grep -v -E 'grep|experiments.py'")
    return output.splitlines()


def pids(pattern):
    code, output = sh(["pgrep", "-f", pattern])
    return [int(p) for p in output.split()] if code == 0 else []


def browser_pids():
    """Safari (and its other executables), web apps and copies: the UI processes, not WebKit's."""
    return sorted(set(pids("Safari.app/Contents/MacOS/") + pids("SafariCopy") + pids("Web App.app/Contents/MacOS/Web App")))


def quit_all():
    """Asks Safari to quit (flushes its stores), then ends every Safari, web app and copy left."""
    if pids("Safari.app/Contents/MacOS/Safari"):
        sh(["osascript", "-e", f'tell application id "{SAFARI_ID}" to quit'], timeout=15)
        for _ in range(20):
            if not pids("Safari.app/Contents/MacOS/Safari"):
                break
            time.sleep(0.5)
    for signal in ("-TERM", "-KILL"):
        left = browser_pids()
        if not left:
            break
        sh(["sudo", "-n", "kill", signal] + [str(p) for p in left])
        time.sleep(3 if signal == "-TERM" else 1)


# ---------------------------------------------------------------------------------------------
# Launchers: how one instance is started


def send_url(pid, url):
    return sh(["osascript", "-l", "JavaScript", os.path.join(HERE, "send_url.js"), str(pid), url], timeout=30)


class Launcher:
    """Starts one instance at a URL. `wait` is how long its first report may take."""
    wait = 90
    home = None
    process = None

    def prepare(self, work):
        pass

    def start(self, url):
        raise NotImplementedError

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()


class OpenSafari(Launcher):
    """LaunchServices: `open -b com.apple.Safari URL`, optionally a new instance (-n), another
    environment (--env) and launch arguments (--args, e.g. WebKit's proxy defaults)."""

    def __init__(self, new_instance=False, env=None, args=None):
        self.new_instance, self.env, self.args = new_instance, env or {}, args or []

    def start(self, url):
        command = ["open"] + (["-n"] if self.new_instance else [])
        for key, value in self.env.items():
            command += ["--env", f"{key}={value}"]
        command += ["-b", SAFARI_ID, url] + (["--args"] + self.args if self.args else [])
        code, output = sh(command, timeout=30)
        return {"command": " ".join(shlex.quote(c) for c in command), "exit": code, "output": output}


class EnvHomeSafari(OpenSafari):
    def __init__(self, home):
        self.home = home
        super().__init__(True, {"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": home + "/tmp/"})

    def start(self, url):
        os.makedirs(self.home + "/tmp", exist_ok=True)
        return super().start(url)


class ExecBinary(Launcher):
    """Runs an executable directly (no LaunchServices) with its own HOME/CFFIXED_USER_HOME, then
    hands it the URL with a GURL Apple Event addressed to its PID."""

    def __init__(self, binary, home, wait=60):
        self.binary, self.home, self.wait = binary, home, wait

    def start(self, url):
        os.makedirs(self.home + "/tmp", exist_ok=True)
        env = dict(os.environ, HOME=self.home, CFFIXED_USER_HOME=self.home, TMPDIR=self.home + "/tmp/")
        if not os.path.exists(self.binary):
            return {"command": self.binary, "error": "no such executable"}
        out = open(os.path.join(self.home, "stdout.log"), "a")
        self.process = subprocess.Popen([self.binary], env=env, stdout=out, stderr=subprocess.STDOUT)
        time.sleep(6)
        alive = self.process.poll() is None
        info = {"command": f"HOME=CFFIXED_USER_HOME={self.home} {self.binary}", "pid": self.process.pid,
                "alive_after_6s": alive, "exit": self.process.poll()}
        if alive:
            info["gurl"] = send_url(self.process.pid, url)
        else:
            info["stdout"] = open(os.path.join(self.home, "stdout.log")).read()[-2000:]
            info["log"] = sh(CONSTRAINT_LOG, timeout=120)[1].splitlines()
        return info


class CopiedSafari(Launcher):
    """A copy of Safari.app outside the system volume, as is or with another bundle identifier and
    an ad-hoc signature."""
    wait = 45

    def __init__(self, resign):
        self.resign = resign

    def prepare(self, work):
        name = "SafariCopyResigned.app" if self.resign else "SafariCopy.app"
        self.app = os.path.join(work, name)
        self.notes = {"copy": sh(["ditto", SAFARI_APP, self.app], timeout=300)}
        if self.resign:
            plist = os.path.join(self.app, "Contents", "Info.plist")
            self.notes["identifier"] = sh(["/usr/libexec/PlistBuddy", "-c",
                                           "Set :CFBundleIdentifier dev.local.SafariCopyResigned", plist])
            self.notes["codesign"] = sh(["codesign", "--force", "--deep", "--sign", "-", self.app], timeout=300)
        self.notes["verify"] = sh(["codesign", "--verify", "--verbose=2", self.app], timeout=120)

    def start(self, url):
        code, output = sh(["open", "-n", "-a", self.app, url], timeout=30)
        time.sleep(5)
        running = pids(self.app)
        info = {"command": f"open -n -a {self.app} URL", "exit": code, "output": output, "running_pids": running,
                "notes": self.notes}
        if not running:
            # Straight exec, to see the kernel's answer rather than LaunchServices'.
            binary = os.path.join(self.app, "Contents", "MacOS", "Safari")
            proc = subprocess.Popen([binary], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            time.sleep(5)
            info["exec"] = {"exit": proc.poll()}
            if proc.poll() is None:
                info["gurl"] = send_url(proc.pid, url)
                self.process = proc
            else:
                info["exec"]["output"] = proc.stdout.read().decode(errors="replace")[-2000:]
        info["log"] = sh(CONSTRAINT_LOG, timeout=120)[1].splitlines()
        info["crash_reports"] = sh("ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | head -5")[1].splitlines()
        return info


class OtherUserSafari(Launcher):
    """Safari for another macOS user, started from this user's session (no GUI login of its own)."""
    wait = 45

    def prepare(self, work):
        self.notes = {}
        if sh(["id", OTHER_USER])[0] != 0:
            self.notes["create"] = sh(["sudo", "-n", "sysadminctl", "-addUser", OTHER_USER, "-fullName", "SP probe",
                                       "-password", "sp-" + os.urandom(6).hex(), "-home", f"/Users/{OTHER_USER}"],
                                      timeout=120)
            self.notes["home"] = sh(["sudo", "-n", "createhomedir", "-c", "-u", OTHER_USER], timeout=120)
        self.uid = sh(["id", "-u", OTHER_USER])[1].strip()

    def start(self, url):
        command = ["sudo", "-n", "launchctl", "asuser", self.uid, "sudo", "-n", "-u", OTHER_USER,
                   "open", "-b", SAFARI_ID, url]
        code, output = sh(command, timeout=60)
        time.sleep(5)
        return {"command": " ".join(command), "exit": code, "output": output, "notes": self.notes,
                "gui_domain": sh(["sudo", "-n", "launchctl", "print", f"gui/{self.uid}"], timeout=30)[1][:600],
                "processes": sh(f"ps -axo pid,user,command | grep -E '^ *[0-9]+ {OTHER_USER} ' | head -20")[1],
                "container": sh(["sudo", "-n", "ls", f"/Users/{OTHER_USER}/Library/Containers"])[1][:600]}

    def stop(self):
        sh(["sudo", "-n", "pkill", "-KILL", "-u", OTHER_USER])


class WebApp(Launcher):
    """A Safari web app (macOS 14+), created through Safari's File > Add to Dock from this harness's
    /app?name=<name> page, launched with `open <bundle>`. Its start URL is fixed; the report server
    redirects it to whatever this launch should run."""

    def __init__(self, name, reports, args=None):
        self.name, self.reports, self.args = name, reports, args or []
        self.bundle = os.path.expanduser(f"~/Applications/SPWA-{name}.app")
        self.notes = {}

    def create(self):
        start = self.reports.url(f"/app?name={self.name}")
        self.notes["open_in_safari"] = sh(["open", "-b", SAFARI_ID, start], timeout=30)
        time.sleep(5)
        self.notes["add_to_dock"] = sh(["osascript", os.path.join(HERE, "add_to_dock.applescript"), f"SPWA-{self.name}"],
                                       timeout=60)
        for _ in range(30):
            if os.path.exists(os.path.join(self.bundle, "Contents", "Info.plist")):
                break
            time.sleep(1)
        exists = os.path.exists(self.bundle)
        self.notes["created"] = exists
        if exists:
            self.notes["bundle_files"] = sh(["find", self.bundle])[1].splitlines()
            self.notes["info_plist"] = sh(["plutil", "-p", os.path.join(self.bundle, "Contents", "Info.plist")])[1]
            self.notes["codesign"] = sh(f"codesign -dvvv {shlex.quote(self.bundle)} 2>&1 | "
                                        "grep -v -E '^(Hash|CandidateCDHash|CDHash)'")[1]
            self.notes["bundle_id"] = sh(["plutil", "-extract", "CFBundleIdentifier", "raw",
                                          os.path.join(self.bundle, "Contents", "Info.plist")])[1]
        else:
            self.notes["ui"] = sh(["osascript", "-e", 'tell application "System Events" to tell process "Safari" '
                                   'to get {name of every menu item of menu 1 of menu bar item 3 of menu bar 1, '
                                   'name of every window}'], timeout=30)
        return exists

    def start(self, url):
        if not os.path.exists(self.bundle):
            return {"command": f"open {self.bundle}", "error": "web app was not created"}
        self.reports.set_plan(self.name, url)
        command = ["open", self.bundle] + (["--args"] + self.args if self.args else [])
        code, output = sh(command, timeout=30)
        time.sleep(3)
        return {"command": " ".join(shlex.quote(c) for c in command), "exit": code, "output": output,
                "web_app_pids": pids("Web App.app/Contents/MacOS/Web App")}


# ---------------------------------------------------------------------------------------------
# Experiments: the instances each launches, in order, and what the result would mean


def proxy_args(proxy):
    return ["-WebKit2HTTPSProxy", f"http://127.0.0.1:{proxy.port}"]


def experiment_specs(work_root, reports, proxy):
    return {
        "baseline": {
            "about": "Safari as a user opens it (LaunchServices, `open -b com.apple.Safari URL`): the reference "
                     "for storage behaviour and for the TLS/HTTP2 fingerprint.",
            "instances": [("s1", OpenSafari())], "navtls": ["s1"],
        },
        "webapps": {
            "about": "Two Safari web apps (File > Add to Dock, macOS 14+) for the same origin, created by UI "
                     "scripting, plus Safari itself. Web app A gets WebKit's per-process HTTPS proxy default "
                     "as a launch argument (-WebKit2HTTPSProxy). Separate processes? Separate data? Safari's "
                     "TLS? Safari-only APIs (ApplePaySession, PushManager)?",
            "instances": [("s8", OpenSafari()), ("wa", WebApp("A", reports, proxy_args(proxy))),
                          ("wb", WebApp("B", reports))],
            "setup": "webapps",
        },
        "open-n": {
            "about": "`open -n` asks LaunchServices for a NEW instance of an app that is already running. Does a "
                     "second Safari process start, does it get its own storage, and does the per-process proxy "
                     "default (-WebKit2HTTPSProxy launch argument) apply to it alone?",
            "instances": [("s2", OpenSafari()), ("n2", OpenSafari(new_instance=True, args=proxy_args(proxy)))],
        },
        "env-home": {
            "about": "A second instance with HOME, CFFIXED_USER_HOME and TMPDIR pointing elsewhere "
                     "(`open -n --env`). Does Safari (a sandboxed app) store anything under the other home?",
            "instances": [("s3", OpenSafari()), ("h3", EnvHomeSafari(os.path.join(work_root, "env-home", "home-h3")))],
        },
        "exec-home": {
            "about": "Safari's executable started directly (not through LaunchServices) with another HOME and "
                     "CFFIXED_USER_HOME, the URL handed over by a PID-addressed Apple Event.",
            "instances": [("s4", OpenSafari()),
                          ("e4", ExecBinary(SAFARI_BIN, os.path.join(work_root, "exec-home", "home-e4")))],
        },
        "sfwd": {
            "about": "SafariForWebKitDevelopment, the second executable inside Safari.app (WebKit's run-safari "
                     "uses it), twice, each with its own CFFIXED_USER_HOME: Safari's UI without Safari's sandbox "
                     "container. Isolated? Which Safari-only APIs remain?",
            "instances": [("s5", OpenSafari()),
                          ("f5", ExecBinary(SAFARI_DEV_BIN, os.path.join(work_root, "sfwd", "home-f5"))),
                          ("g5", ExecBinary(SAFARI_DEV_BIN, os.path.join(work_root, "sfwd", "home-g5")))],
        },
        "copy": {
            "about": "A copy of Safari.app run from another folder, unchanged and with a new bundle identifier "
                     "and an ad-hoc signature: does macOS run it at all (launch constraints, AMFI)?",
            "instances": [("c6", CopiedSafari(resign=False)), ("r6", CopiedSafari(resign=True))],
        },
        "other-user": {
            "about": "Safari as another macOS user (created with sysadminctl) started from this user's GUI "
                     "session with `launchctl asuser … sudo -u … open`; that user has no GUI login of its own.",
            "instances": [("u7", OtherUserSafari())],
        },
    }


def all_instance_names(specs, names):
    result = []
    for name in names:
        if name in specs:
            result += [inst for inst, _ in specs[name]["instances"]]
        elif name == "reference":
            result.append("wd")
    return result


# ---------------------------------------------------------------------------------------------
# Hosts, certificates


def setup_hosts(instances):
    names = [f"{inst}.{TLS_DOMAIN}" for inst in instances]
    code, current = sh("cat /etc/hosts")
    missing = [n for n in names if f" {n}" not in current]
    if missing:
        text = "".join(f"127.0.0.1 {n}\n" for n in missing)
        code, output = sh(f"printf %s {shlex.quote(text)} | sudo -n tee -a /etc/hosts >/dev/null")
        log(f"/etc/hosts: added {len(missing)} names (exit {code}) {output}")
        sh("sudo -n dscacheutil -flushcache; sudo -n killall -HUP mDNSResponder")
    log(f"resolve {names[0]}: " + sh(f"dscacheutil -q host -a name {names[0]}")[1].replace("\n", " "))


def make_ca_and_leaf(directory, instances, trust):
    """A throwaway CA and a leaf for every instance's TLS host. With `trust`, the CA is trusted in
    the System keychain (sudo; for disposable machines)."""
    names = [f"{inst}.{TLS_DOMAIN}" for inst in instances]
    ca_key, ca = os.path.join(directory, "ca.key"), os.path.join(directory, "ca.pem")
    key, csr, leaf = (os.path.join(directory, n) for n in ("leaf.key", "leaf.csr", "leaf.pem"))
    ca_cnf, leaf_ext = os.path.join(directory, "ca.cnf"), os.path.join(directory, "leaf.ext")
    with open(ca_cnf, "w") as handle:
        handle.write("[req]\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n[v3]\n"
                     "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
                     "subjectKeyIdentifier=hash\n")
    with open(leaf_ext, "w") as handle:
        handle.write("basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                     "extendedKeyUsage=serverAuth\nsubjectAltName=" + ",".join(f"DNS:{n}" for n in names) + "\n")
    steps = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", ca_key, "-out", ca, "-days", "7",
         "-subj", "/CN=Safari process experiment CA (throwaway)", "-config", ca_cnf],
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", f"/CN={names[0]}"],
        ["openssl", "x509", "-req", "-in", csr, "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-out", leaf,
         "-days", "7", "-sha256", "-extfile", leaf_ext],
    ]
    for step in steps:
        code, output = sh(step)
        if code:
            log(f"certificate step failed: {' '.join(step)}\n{output}")
            return None, None, False
    trusted = False
    if trust:
        code, output = sh(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k",
                           "/Library/Keychains/System.keychain", ca], timeout=60)
        trusted = code == 0
        log(f"trust throwaway CA in the System keychain: exit {code} {output}")
    return leaf, key, trusted


# ---------------------------------------------------------------------------------------------
# Running an experiment


def run_url(reports, inst, run, seed, peers, tls_port, navtls=False):
    path = f"/run?inst={inst}&run={run}&seed={1 if seed else 0}"
    if peers:
        path += "&peers=" + ",".join(peers)
    if tls_port:
        path += f"&tls=https://{inst}.{TLS_DOMAIN}:{tls_port}/{inst}"
        if navtls:
            path += "&navtls=1"
    return reports.url(path)


def summarize_tls(records):
    if not records:
        return None
    first = next((r for r in records if "ja4" in r), records[0])
    out = {k: first.get(k) for k in ("ja3_hash", "ja4", "stable_hash", "negotiated", "handshake_error", "error")}
    out["connections"] = len(records)
    out["ja4_all"] = sorted({r.get("ja4") for r in records if r.get("ja4")})
    out["stable_all"] = sorted({r.get("stable_hash") for r in records if r.get("stable_hash")})
    out["shape"] = first.get("shape")
    h2 = [r["http2"] for r in records if r.get("http2")]
    if h2:
        out["akamai"] = h2[0]["akamai"]
        out["akamai_all"] = sorted({h["akamai"] for h in h2})
        out["http2_header_orders"] = sorted({",".join(h["header_order"]) for h in h2})
    return out


def verdict(inst, insts, seeded, final, relaunch):
    own_kinds = ["httpOnlyCookie", "scriptCookie", "localStorage", "indexedDB"]
    result = {"reported": bool(final or seeded)}
    if seeded and seeded.get("tags"):
        result["wrote_own_markers"] = {k: inst in seeded["tags"][k] for k in own_kinds}
    # Two processes on one store need not see each other's fresh writes at once (each keeps its
    # own caches), so the final read of run 1 and the first read after a relaunch both count.
    seen = set()
    for report in (final, relaunch):
        if report and report.get("tags"):
            seen |= {t for k in own_kinds for t in report["tags"][k]}
    if relaunch and relaunch.get("tags"):
        result["after_relaunch_has_own"] = {k: inst in relaunch["tags"][k] for k in own_kinds}
    if final or relaunch:
        foreign = sorted(seen - {inst})
        # Markers of this experiment's other instances; those left by earlier experiments in the
        # same store are listed apart (they say which store this instance uses).
        result["sees_markers_of"] = [t for t in foreign if t in insts]
        result["also_sees_earlier"] = [t for t in foreign if t not in insts]
        result["isolated_from_other_instances"] = not result["sees_markers_of"]
    return result


def setup_webapps(spec, result):
    """Creates the experiment's web apps through Safari's UI (File > Add to Dock)."""
    quit_all()
    for inst, launcher in spec["instances"]:
        if isinstance(launcher, WebApp):
            if os.path.exists(launcher.bundle):
                shutil.rmtree(launcher.bundle, ignore_errors=True)
            created = launcher.create()
            log(f"[{inst}] web app created: {created} {json.dumps(launcher.notes.get('add_to_dock'))}")
            if not created:
                log(f"[{inst}] UI: {json.dumps(launcher.notes.get('ui'))}")
            quit_all()
    result["webapps"] = {inst: launcher.notes for inst, launcher in spec["instances"] if isinstance(launcher, WebApp)}
    result["web_app_container"] = sh("ls -la ~/Library/Containers/com.apple.Safari.WebApp/Data/Library 2>&1; "
                                     "find ~/Library/Containers/com.apple.Safari.WebApp/Data/Library -maxdepth 4 "
                                     "-type d 2>&1 | head -60")[1].splitlines()
    result["template_app_vault"] = sh("ls -la ~/Library/Application\\ Support/com.apple.LaunchServicesTemplateApp.dv 2>&1")[1]
    result["lsregister"] = sh("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/"
                              "Support/lsregister -dump 2>/dev/null | grep -n -E 'SPWA-|com.apple.Safari.WebApp' | head -40",
                              timeout=120)[1].splitlines()


def run_experiment(name, spec, reports, tls, proxy, out_dir, tls_port):
    log(f"\n=== {name}: {spec['about']}")
    quit_all()
    work = os.path.join(out_dir, name)
    os.makedirs(work, exist_ok=True)
    result = {"about": spec["about"], "instances": {}, "launch": {}, "relaunch": {}}
    for inst, launcher in spec["instances"]:
        launcher.prepare(work)
    if spec.get("setup") == "webapps":
        setup_webapps(spec, result)
    marker = os.path.join(work, ".start")
    open(marker, "w").close()
    time.sleep(1.1)
    insts = [inst for inst, _ in spec["instances"]]
    launchers = dict(spec["instances"])
    proxy_before = len(proxy.hosts())

    # Run 1: every instance writes its markers; each waits for the others before its final read.
    for inst in insts:
        peers = [p for p in insts if p != inst]
        url = run_url(reports, inst, 1, True, peers, tls_port, inst in spec.get("navtls", []))
        result["launch"][inst] = launchers[inst].start(url)
        log(f"[{inst}] launch: {json.dumps(result['launch'][inst], default=str)[:1500]}")
        pre = reports.wait(inst, "pre", timeout=launchers[inst].wait)
        log(f"[{inst}] pre: {pre.get('tags') if pre else 'NO REPORT'}")
        time.sleep(2)
        result.setdefault("pids_after_launch", {})[inst] = browser_pids()
    finals = {inst: reports.wait(inst, "final", timeout=150 if reports.wait(inst, "pre", timeout=0) else 0)
              for inst in insts}
    for inst in insts:
        if finals[inst]:
            reports.wait(inst, "tls", timeout=20)
    time.sleep(4)  # the TLS fetch, and time for the stores to flush
    result["processes"] = processes()
    log("processes:\n  " + "\n  ".join(result["processes"]))
    for inst in insts:
        result["instances"][inst] = {
            "pre": reports.wait(inst, "pre", timeout=0),
            "seeded": reports.wait(inst, "seeded", timeout=0),
            "final": finals[inst],
            "tls_report": reports.wait(inst, "tls", timeout=0),
            "tls": summarize_tls(tls.for_host(f"{inst}.{TLS_DOMAIN}")),
            "proxied": [h for h in proxy.hosts()[proxy_before:] if f"{inst}.{TLS_DOMAIN}" in h],
        }
    quit_all()
    for launcher in launchers.values():
        launcher.stop()

    # Run 2: each instance alone, launched the same way: are its own markers still there?
    for inst in insts:
        if not result["instances"][inst]["pre"]:
            continue
        result["relaunch"][inst] = launchers[inst].start(run_url(reports, inst, 2, False, [], None))
        result["instances"][inst]["relaunch"] = reports.wait(inst, "pre", run="2", timeout=launchers[inst].wait)
        time.sleep(1)
        quit_all()
        launchers[inst].stop()

    # Where did the instances write? (Containers of other apps may be hidden from this process.)
    result["written"] = {}
    for label, path in [("Safari container", "~/Library/Containers/com.apple.Safari/Data/Library"),
                        ("Web app container", "~/Library/Containers/com.apple.Safari.WebApp/Data/Library"),
                        ("~/Library/Safari", "~/Library/Safari"), ("~/Library/WebKit", "~/Library/WebKit"),
                        ("~/Library/Caches", "~/Library/Caches")] + \
                       [(f"home of {inst}", launchers[inst].home) for inst in insts if launchers[inst].home]:
        code, output = sh(f"find {path} -newer {shlex.quote(marker)} -type f 2>&1 | grep -v -E '/(Logs|tmp)/' | head -60")
        result["written"][label] = output.splitlines()
    for inst in insts:
        info = result["instances"][inst]
        info["verdict"] = verdict(inst, insts, info["seeded"], info["final"], info.get("relaunch"))
        log(f"[{inst}] verdict: {json.dumps(info['verdict'])}")
        log(f"[{inst}] tls: {json.dumps({k: v for k, v in (info['tls'] or {}).items() if k != 'shape'})}")
        if info["proxied"]:
            log(f"[{inst}] went through the proxy: {info['proxied']}")
    with open(os.path.join(out_dir, f"{name}.json"), "w") as handle:
        json.dump(result, handle, indent=1, sort_keys=True, default=str)
    return result


def run_reference(tls, out_dir, tls_port):
    """Safari under safaridriver: the same local TLS capture, and tls.peet.ws's own reading of the
    same Safari, to check this harness's JA3/JA4/Akamai against an independent implementation."""
    log("\n=== reference: Safari under safaridriver, local capture and tls.peet.ws")
    quit_all()
    from safari_reference import WebDriver, free_port, wait_for_port  # scripts/safari_reference.py
    port = free_port()
    driver_process = subprocess.Popen(["safaridriver", "-p", str(port)], stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT)
    result = {}
    try:
        if not wait_for_port(port, 20):
            result["error"] = "safaridriver did not start"
            return result
        driver = WebDriver(f"http://127.0.0.1:{port}")
        capabilities = driver.start()
        result["browserVersion"] = capabilities.get("browserVersion")
        try:
            try:
                driver.navigate(f"https://wd.{TLS_DOMAIN}:{tls_port}/wd?via=navigation")
            except Exception as exc:  # noqa: BLE001 - an untrusted certificate fails the navigation
                result["local_navigation_error"] = str(exc)[:300]
            try:
                driver.navigate("https://tls.peet.ws/api/all")
                data = json.loads(driver.execute("return document.body.innerText"))
                tls_data, h2 = data.get("tls") or {}, data.get("http2") or {}
                frames = h2.get("sent_frames") or []
                headers = (next((f for f in frames if f.get("frame_type") == "HEADERS"), {}) or {}).get("headers", [])
                result["peet"] = {"ja3_hash": tls_data.get("ja3_hash"), "ja3": tls_data.get("ja3"),
                                  "ja4": tls_data.get("ja4"), "ja4_r": tls_data.get("ja4_r"),
                                  "peetprint_hash": tls_data.get("peetprint_hash"),
                                  "akamai": h2.get("akamai_fingerprint"),
                                  "header_order": [h[:h.index(":", 1)] for h in headers if ":" in h[1:]],
                                  "http_version": data.get("http_version")}
            except Exception as exc:  # noqa: BLE001 - the site may be down
                result["peet_error"] = str(exc)[:300]
        finally:
            driver.quit()
    finally:
        driver_process.terminate()
        try:
            driver_process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            driver_process.kill()
    time.sleep(1)
    result["local"] = summarize_tls(tls.for_host(f"wd.{TLS_DOMAIN}"))
    local, peet = result.get("local") or {}, result.get("peet") or {}
    result["agree"] = {"ja4": bool(local.get("ja4")) and local.get("ja4") == peet.get("ja4"),
                       "akamai": bool(local.get("akamai")) and local.get("akamai") == peet.get("akamai")}
    log(f"reference: {json.dumps({k: v for k, v in result.items() if k != 'local'})}")
    log(f"reference local: {json.dumps({k: v for k, v in local.items() if k != 'shape'})}")
    with open(os.path.join(out_dir, "reference.json"), "w") as handle:
        json.dump(result, handle, indent=1, sort_keys=True)
    quit_all()
    return result


def comparison_table(results, reference):
    """One line per instance: storage isolation, persistence, and TLS against plain Safari (s1)."""
    base = (results.get("baseline", {}).get("instances", {}).get("s1") or {}).get("tls")
    lines = ["| experiment | instance | launched as | new UI pid | wrote markers | sees other instances "
             "| own markers after relaunch | JA4 | ClientHello = Safari s1 | HTTP/2 = Safari s1 | proxied "
             "| ApplePaySession / PushManager |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for name, result in results.items():
        launch_pids = result.get("pids_after_launch", {})
        order = list(result["instances"])
        for index, inst in enumerate(order):
            info = result["instances"][inst]
            v, tls_info = info["verdict"], info.get("tls") or {}
            wrote, relaunch = v.get("wrote_own_markers"), v.get("after_relaunch_has_own")
            same_hello = same_h2 = "n/a"
            if base and tls_info:
                same_hello = "yes" if tls_info.get("stable_hash") == base.get("stable_hash") else "NO"
                if base.get("akamai") and tls_info.get("akamai"):
                    same_h2 = "yes" if tls_info["akamai"] == base["akamai"] else "NO"
            env = ((info.get("pre") or {}).get("env") or {})
            apis = f"{env.get('applePaySession', '?')} / {env.get('pushManager', '?')}" if env else "no report"
            launch = result["launch"].get(inst, {})
            before = set(launch_pids.get(order[index - 1], [])) if index else set()
            new_pids = sorted(set(launch_pids.get(inst, [])) - before)
            lines.append("| " + " | ".join([
                name, inst, (launch.get("command") or launch.get("error") or "")[:70].replace("|", "\\|"),
                ",".join(map(str, new_pids)) if new_pids else "none",
                ("all" if wrote and all(wrote.values()) else json.dumps(wrote)) if wrote else "no report",
                ", ".join(v.get("sees_markers_of", [])) or ("none" if "sees_markers_of" in v else "no report"),
                ("all" if relaunch and all(relaunch.values()) else json.dumps(relaunch)) if relaunch else "no report",
                tls_info.get("ja4") or "not captured", same_hello, same_h2,
                "yes" if info.get("proxied") else "no", apis]) + " |")
    if reference:
        local, peet = reference.get("local") or {}, reference.get("peet") or {}
        lines.append("")
        lines.append(f"Reference (safaridriver, Safari {reference.get('browserVersion')}): this harness JA4 "
                     f"`{local.get('ja4')}`, tls.peet.ws JA4 `{peet.get('ja4')}`; this harness Akamai "
                     f"`{local.get('akamai')}`, tls.peet.ws Akamai `{peet.get('akamai')}`; same ClientHello as s1: "
                     f"{'yes' if base and local.get('stable_hash') == base.get('stable_hash') else 'NO/n.a.'}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report-port", type=int, default=8765)
    parser.add_argument("--tls-port", type=int, default=8443)
    parser.add_argument("--setup-hosts", action="store_true", help="add <instance>.sp-tls.test to /etc/hosts (sudo)")
    parser.add_argument("--trust", action="store_true", help="trust a throwaway CA in the System keychain (sudo)")
    parser.add_argument("experiments", nargs="+", help="facts, reference, baseline, webapps, open-n, env-home, "
                                                       "exec-home, sfwd, copy, other-user")
    args = parser.parse_args()
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    if "facts" in args.experiments:
        facts(out_dir)
    names = [n for n in args.experiments if n != "facts"]
    if not names:
        return 0
    reports = harness.ReportServer(port=args.report_port)
    proxy = harness.ConnectProxy()
    specs = experiment_specs(out_dir, reports, proxy)
    instances = all_instance_names(specs, names)
    if args.setup_hosts:
        setup_hosts(instances)
    cert, key, trusted = make_ca_and_leaf(tempfile.mkdtemp(prefix="sp-tls-"), instances, args.trust)
    tls = harness.TLSServer(port=args.tls_port, cert=cert, key=key)
    log(f"report server {reports.url('/')}, TLS server port {tls.port}, proxy port {proxy.port}, CA trusted: {trusted}")

    results, reference = {}, None
    for name in names:
        try:
            if name == "reference":
                reference = run_reference(tls, out_dir, tls.port)
            elif name in specs:
                results[name] = run_experiment(name, specs[name], reports, tls, proxy, out_dir, tls.port)
            else:
                log(f"unknown experiment {name}")
        except Exception as exc:  # noqa: BLE001 - one experiment failing must not stop the others
            log(f"experiment {name} failed: {exc!r}")
    quit_all()
    with open(os.path.join(out_dir, "tls-records.json"), "w") as handle:
        json.dump(tls.records, handle, indent=1, sort_keys=True, default=str)
    with open(os.path.join(out_dir, "reports.json"), "w") as handle:
        json.dump(reports.reports, handle, indent=1, sort_keys=True, default=str)
    with open(os.path.join(out_dir, "proxy-log.json"), "w") as handle:
        json.dump(proxy.log, handle, indent=1)
    table = comparison_table(results, reference)
    with open(os.path.join(out_dir, "summary.md"), "w") as handle:
        handle.write(table + "\n")
    log("\n" + table)
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a") as handle:
            handle.write(f"### Safari process experiments\n\n```\n{sh('sw_vers')[1]}\n```\n\n{table}\n\n")
    reports.close()
    tls.close()
    proxy.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
