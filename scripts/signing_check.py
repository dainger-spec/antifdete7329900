#!/usr/bin/env python3
"""The NE=1 release's signing chain on this Mac, end to end, written to one report to send back
(docs/IDENTITY.md, "What to register with Apple").

    TEAM_ID=<TEAM_ID> SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)" \\
      APP_PROFILE=lumen.provisionprofile EXTENSION_PROFILE=lumen-guard.provisionprofile \\
      NOTARY_PROFILE=lumen-notary python3 scripts/signing_check.py

Then send build/signing-check/report.txt (and notary-log.json, if notarization refused).
`--profiles-only` reads the identity and the profiles alone (a second, no build): step 4 shows there.

1. The identity and both provisioning profiles, read: team, App ID, platform, expiry, the
   certificates each names, and every entitlement each allows. Each entitlement the build claims
   is held against its profile. The app group (`APP_GROUP`, default <TEAM_ID>.io.lumenbrowser.Lumen)
   is step 4 of docs/IDENTITY.md, the step least sure to hold.
2. The release as docs/IDENTITY.md makes it: scripts/release.sh with NE=1, with a throwaway update
   key and the default feed. It builds, signs the extension and the app, notarizes, staples, asks
   Gatekeeper, and starts the app as it ships (--check-safari-chrome, --release-check). A check of
   the chain, not a release to publish.
3. What came of it, read back: both signatures and their entitlements, the embedded profiles,
   notarization (Apple's log when it refuses), the stapled ticket, Gatekeeper (spctl and
   syspolicy_check), and whether macOS lets the extension's binary start with its entitlements
   (AMFI) — a hint only, without installing it: activating it (docs/TUNNEL.md, hardware checklist
   step 1) is the real test.

Nothing is installed and no setting is changed. The report holds no password or key: names, the
team ID, hashes and Apple's messages.
"""
import hashlib
import os
import plistlib
import re
import subprocess
import sys
import time

# The network guard is a content filter (docs/TUNNEL.md); its App ID is still $BUNDLE_ID.PacketTunnel.
NE_PROVIDER = "content-filter-provider-systemextension"
lines = []


def say(text=""):
    print(text, flush=True)
    lines.append(text)


def section(title):
    say("")
    say("== " + title)


def run(command, env=None, timeout=None, log=None):
    """(exit status, output) of a command; never raises. With `log`, the output also goes there."""
    try:
        completed = subprocess.run(command, env=env, timeout=timeout, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
        output = completed.stdout.decode("utf-8", "replace")
        status = completed.returncode
    except subprocess.TimeoutExpired as error:
        output = (error.stdout or b"").decode("utf-8", "replace") + "\n(timed out)"
        status = -1
    except OSError as error:
        output = str(error)
        status = -1
    if log:
        with open(log, "w") as handle:
            handle.write(output)
    return status, output


def run_live(command, env, log):
    """(exit status, output) of a long command, its output shown as it comes and kept in `log`."""
    collected = []
    try:
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as error:
        return -1, str(error)
    with open(log, "w") as handle:
        for raw in process.stdout:
            line = raw.decode("utf-8", "replace")
            sys.stdout.write("  | " + line)
            sys.stdout.flush()
            handle.write(line)
            collected.append(line)
    return process.wait(), "".join(collected)


def decode_profile(path):
    status, _ = run(["security", "cms", "-D", "-i", path, "-o", path + ".plist"])
    if status != 0 or not os.path.exists(path + ".plist"):
        return None
    with open(path + ".plist", "rb") as handle:
        data = handle.read()
    os.remove(path + ".plist")
    return plistlib.loads(data)


def allowed_by(allowed, claimed):
    """Whether a profile's value allows a claimed one: equal, or a trailing-* prefix."""
    if isinstance(allowed, str) and allowed.endswith("*"):
        return isinstance(claimed, str) and claimed.startswith(allowed[:-1])
    return allowed == claimed


def coverage(entitlements, key, claimed):
    """(verdict, note): OK, FAIL, or NOT-LISTED (the profile does not name the key at all)."""
    if key not in entitlements:
        return "NOT-LISTED", "the profile does not list " + key
    allowed = entitlements[key]
    if isinstance(claimed, bool):
        return ("OK", "") if allowed is True else ("FAIL", "the profile has " + repr(allowed))
    if isinstance(claimed, list):
        pool = allowed if isinstance(allowed, list) else [allowed]
        missing = [value for value in claimed if not any(allowed_by(entry, value) for entry in pool)]
        if missing:
            return "FAIL", "not allowed: %s (the profile allows %s)" % (missing, pool)
        return "OK", ""
    if allowed_by(allowed, claimed):
        return "OK", ""
    return "FAIL", "claimed %r, the profile allows %r" % (claimed, allowed)


def claims(team, bundle, extension, group):
    app = {
        "com.apple.application-identifier": team + "." + bundle,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.networking.networkextension": [NE_PROVIDER],
        "com.apple.developer.system-extension.install": True,
        "com.apple.security.application-groups": [group],
    }
    guard = {
        "com.apple.application-identifier": team + "." + extension,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.networking.networkextension": [NE_PROVIDER],
        "com.apple.security.application-groups": [group],
    }
    return app, guard


def describe_profile(label, path, identity_sha1, claimed):
    """Reads one profile into the report; returns its verdicts {key: verdict}."""
    section("Profile: " + label + " (" + path + ")")
    if not os.path.exists(path):
        say("FAIL no such file")
        return {"file": "FAIL"}
    profile = decode_profile(path)
    if profile is None:
        say("FAIL `security cms -D` could not read it: not a provisioning profile")
        return {"file": "FAIL"}
    entitlements = profile.get("Entitlements", {})
    say("name %r, uuid %s" % (profile.get("Name"), profile.get("UUID")))
    say("team %s, App ID name %r, platform %s" % (profile.get("TeamIdentifier"), profile.get("AppIDName"),
                                                  profile.get("Platform")))
    say("created %s, expires %s, all devices (Developer ID): %s"
        % (profile.get("CreationDate"), profile.get("ExpirationDate"), profile.get("ProvisionsAllDevices", False)))
    hashes = [hashlib.sha1(certificate).hexdigest().upper() for certificate in profile.get("DeveloperCertificates", [])]
    say("certificates (SHA-1): " + ", ".join(hashes))
    verdicts = {}
    if identity_sha1:
        verdicts["certificate"] = "OK" if identity_sha1 in hashes else "FAIL"
        say("%s the signing identity's certificate %s the profile"
            % (verdicts["certificate"], "is in" if identity_sha1 in hashes else "is NOT in"))
    say("entitlements the profile allows:")
    for key in sorted(entitlements):
        say("  %s = %r" % (key, entitlements[key]))
    say("entitlements the build claims, held against the profile:")
    for key, value in claimed.items():
        verdict, note = coverage(entitlements, key, value)
        verdicts[key] = verdict
        say("  %-10s %s = %r%s" % (verdict, key, value, ("  — " + note) if note else ""))
    return verdicts


def first_line(text):
    return (text.strip().splitlines() or ["?"])[0]


def find(pattern, text, group=1):
    match = re.search(pattern, text, re.M)
    return match.group(group) if match else None


def main():
    env = dict(os.environ)
    needed = ["TEAM_ID", "SIGN_IDENTITY", "APP_PROFILE", "EXTENSION_PROFILE", "NOTARY_PROFILE"]
    missing = [name for name in needed if not env.get(name)]
    if missing:
        print("set " + ", ".join(missing) + " (see the top of this file and docs/IDENTITY.md)", file=sys.stderr)
        return 2
    if sys.platform != "darwin":
        print("this runs on the Mac that holds the Developer ID certificate", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    team, identity = env["TEAM_ID"], env["SIGN_IDENTITY"]
    bundle = env.get("BUNDLE_ID", "io.lumenbrowser.Lumen")
    extension = env.get("EXTENSION_ID", bundle + ".PacketTunnel")
    group = env.get("APP_GROUP", team + "." + bundle)
    out = os.path.abspath(env.get("CHECK_OUT", "build/signing-check"))
    os.makedirs(out, exist_ok=True)
    summary = []

    section("This Mac")
    say("macOS " + run(["sw_vers", "-productVersion"])[1].strip() + " (" + run(["sw_vers", "-buildVersion"])[1].strip()
        + "), " + run(["uname", "-m"])[1].strip())
    say("Xcode: " + " ".join(run(["xcodebuild", "-version"])[1].split()))
    say("SDK " + run(["xcrun", "--show-sdk-version"])[1].strip() + "; " + first_line(run(["swift", "--version"])[1]))
    say("team %s, bundle %s, extension %s, app group %s" % (team, bundle, extension, group))

    section("The signing identity")
    _, identities = run(["security", "find-identity", "-v", "-p", "codesigning"])
    identity_sha1 = None
    for line in identities.splitlines():
        match = re.match(r'\s*\d+\)\s+([0-9A-F]{40})\s+"(.*)"', line)
        if match and match.group(2) == identity:
            identity_sha1 = match.group(1)
    if identity_sha1:
        say("OK %r is in this Mac's keychains, certificate SHA-1 %s" % (identity, identity_sha1))
    else:
        say("FAIL %r is not a valid code-signing identity here. `security find-identity -v -p codesigning`:" % identity)
        for line in identities.splitlines():
            say("  " + line.strip())
    summary.append(("identity", "OK" if identity_sha1 else "FAIL"))

    app_claims, guard_claims = claims(team, bundle, extension, group)
    app_verdicts = describe_profile("the app, APP_PROFILE", env["APP_PROFILE"], identity_sha1, app_claims)
    guard_verdicts = describe_profile("the extension, EXTENSION_PROFILE", env["EXTENSION_PROFILE"], identity_sha1,
                                      guard_claims)
    for label, verdicts in (("app profile", app_verdicts), ("extension profile", guard_verdicts)):
        # A restricted entitlement the profile does not list is refused at launch, like a wrong value.
        others = [v for k, v in verdicts.items() if k != "com.apple.security.application-groups"]
        summary.append((label, "OK" if others and all(v == "OK" for v in others) else "FAIL"))
        summary.append((label + ": app group " + group,
                        verdicts.get("com.apple.security.application-groups", "FAIL")))

    if "--profiles-only" in sys.argv:
        section("Summary (profiles only: no build)")
        for label, verdict in summary:
            say("%-10s %s" % (verdict, label))
        with open(os.path.join(out, "report.txt"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        print("\nReport: " + os.path.join(out, "report.txt"))
        return 0 if all(v.startswith("OK") for _, v in summary) else 1

    section("The release, NE=1 (scripts/release.sh; its output: release.log)")
    release_env = dict(env, NE="1", VERSION=env.get("CHECK_VERSION", "0.1.0"), BUILD=env.get("CHECK_BUILD", "1"),
                       OUT=os.path.join(out, "release"))
    release_env.pop("UPDATE_KEY_FILE", None)  # a throwaway update key: a check of signing, not a release
    started = time.time()
    say("(about ten minutes: the build, then Apple's notary service)")
    status, log = run_live(["scripts/release.sh"], release_env, os.path.join(out, "release.log"))
    say("exit status %d after %d s" % (status, time.time() - started))
    app = os.path.join(out, "release", "app", "Lumen.app")
    sysext = os.path.join(app, "Contents", "Library", "SystemExtensions", extension + ".systemextension")
    built = "App Sandbox OFF" in log and os.path.isdir(sysext)
    submission = find(r"^\s*id: ([0-9a-f-]{36})\s*$", log)
    notarized = find(r"^\s*status: (\w[\w ]*)$", log)
    stapled = "The staple and validate action worked" in log
    gatekeeper = bool(re.search(r": accepted\s*\n\s*source=Notarized Developer ID", log))
    # Every line of the release check, never the first PASS alone: the keychain between profiles is
    # checked after the profile's window, and its FAIL is the check failed (release_check_gate.sh).
    checks = re.findall(r"^RELEASE-CHECK (PASS|FAIL|INFO) (.*)$", log, re.M)
    failed = [text for verdict, text in checks if verdict == "FAIL"]
    window = any(verdict == "PASS" and text.startswith("a profile in a process of its own") for verdict, text in checks)
    keychain = [(verdict, text) for verdict, text in checks
                if text.startswith("keychain") or text.startswith("not shown in this build: keychain")]
    keychain_failed = [text for verdict, text in keychain if verdict == "FAIL"]
    keychain_passed = [text for verdict, text in keychain if verdict == "PASS"]
    keychain_unshown = [text for verdict, text in keychain if verdict == "INFO" and text.startswith("not shown")]
    summary.append(("built and signed: app and extension", "OK" if built else "FAIL"))
    summary.append(("notarization", ("OK " if notarized == "Accepted" else "FAIL ") + str(notarized)
                    if submission else "NOT-RUN"))
    summary.append(("ticket stapled", "OK" if stapled else "NOT-RUN"))
    summary.append(("Gatekeeper (spctl, during the release)", "OK" if gatekeeper else "NOT-RUN"))
    summary.append(("the app as it ships starts (release check)",
                    ("FAIL " + failed[0][:160]) if failed else ("OK" if window else "NOT-RUN")))
    # Shown only on a build the team signed: both of its checks PASS here, or this is not done.
    summary.append(("keychain between profiles (release check)",
                    ("FAIL " + keychain_failed[0][:160]) if keychain_failed
                    else "OK" if len(keychain_passed) >= 2 and not keychain_unshown
                    else ("NOT-SHOWN " + keychain_unshown[0][:160]) if keychain_unshown
                    else "NOT-RUN"))
    if status != 0:
        say("the release stopped; its last lines:")
        for line in log.strip().splitlines()[-25:]:
            say("  " + line)
    if "Killed: 9" in log:
        say("NOTE a process was killed (Killed: 9): macOS refused a signature or its entitlements (AMFI); see below")

    if submission:
        section("Notarization, submission " + submission)
        say("status: " + str(notarized))
        _, notary_log = run(["xcrun", "notarytool", "log", submission, "--keychain-profile", env["NOTARY_PROFILE"]],
                            log=os.path.join(out, "notary-log.json"))
        issues = re.findall(r'"message"\s*:\s*"([^"]*)"', notary_log)
        paths = re.findall(r'"path"\s*:\s*"([^"]*)"', notary_log)
        say("Apple's log (notary-log.json): %d issue(s)" % len(issues))
        for index, message in enumerate(issues[:20]):
            say("  - %s%s" % (message, (" — " + paths[index]) if index < len(paths) else ""))

    if os.path.isdir(app):
        section("The app, read back")
        for label, path in (("app", app), ("extension", sysext)):
            if not os.path.isdir(path):
                say("FAIL no " + label + " at " + path)
                continue
            _, details = run(["codesign", "-dvvv", path])
            for line in details.splitlines():
                if re.match(r"(Identifier|Format|CodeDirectory|Authority|TeamIdentifier|Timestamp|Runtime Version|Notarization Ticket)", line):
                    say("  %s: %s" % (label, line.strip()))
            _, signed = run(["codesign", "-d", "--entitlements", "-", "--xml", path])
            start = signed.find("<?xml")
            if start >= 0:
                try:
                    entitlements = plistlib.loads(signed[start:].encode())
                    for key in sorted(entitlements):
                        say("  %s entitlement %s = %r" % (label, key, entitlements[key]))
                except Exception as error:  # an unreadable dump is reported, not fatal
                    say("  %s entitlements unreadable: %s" % (label, error))
            embedded = decode_profile(os.path.join(path, "Contents", "embedded.provisionprofile"))
            say("  %s embedded profile: %s" % (label, (embedded or {}).get("UUID", "none")))
        status_verify, verify = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
        say("codesign --verify --deep --strict: exit %d — %s" % (status_verify, " | ".join(verify.strip().splitlines()[-3:])))
        status_spctl, spctl = run(["spctl", "--assess", "--type", "execute", "-vvv", app])
        say("spctl --assess: exit %d — %s" % (status_spctl, " | ".join(spctl.strip().splitlines())))
        summary.append(("Gatekeeper (spctl, read back)", "OK" if status_spctl == 0 else "FAIL"))
        status_staple, staple = run(["xcrun", "stapler", "validate", app])
        say("stapler validate: exit %d — %s" % (status_staple, " | ".join(staple.strip().splitlines()[-2:])))
        if os.path.exists("/usr/bin/syspolicy_check"):
            status_policy, policy = run(["syspolicy_check", "distribution", app], timeout=300,
                                        log=os.path.join(out, "syspolicy_check.txt"))
            say("syspolicy_check distribution: exit %d — %s"
                % (status_policy, " | ".join(policy.strip().splitlines()[-6:])))
            summary.append(("syspolicy_check distribution", "OK" if status_policy == 0 else "FAIL"))

        binary = os.path.join(sysext, "Contents", "MacOS", "NetworkGuardExtension")
        if os.path.exists(binary):
            section("The extension's binary started for 4 s (AMFI; nothing is installed)")
            started = time.time()
            try:
                process = subprocess.Popen([binary], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    code = process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    code = None
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            except OSError as error:
                code = -9
                say("  it could not be started: %s" % error)
            lived = time.time() - started
            if code is None:
                verdict = "OK"
                say("OK it ran for 4 s with its entitlements: AMFI accepted them (stopped by this script)")
            elif code == -9 and lived < 1:
                verdict = "FAIL"
                say("FAIL killed at once (SIGKILL after %.2f s): macOS refused its signature or entitlements" % lived)
            else:
                verdict = "UNCLEAR"
                say("UNCLEAR it exited with %d after %.2f s (not an AMFI kill by its look; see the log lines)" % (code, lived))
            _, amfi = run(["log", "show", "--last", "2m", "--style", "compact", "--predicate",
                           'eventMessage CONTAINS[c] "NetworkGuard" AND '
                           '(process == "kernel" OR process == "amfid" OR process == "taskgated-helper")'], timeout=120)
            for line in [l for l in amfi.splitlines() if "NetworkGuard" in l][-10:]:
                say("  log: " + line.strip()[:400])
            summary.append(("extension binary starts with its entitlements (AMFI hint)", verdict))

    section("Summary")
    for label, verdict in summary:
        say("%-10s %s" % (verdict, label))
    with open(os.path.join(out, "report.txt"), "w") as handle:
        handle.write("\n".join(lines) + "\n")
    print("\nReport: " + os.path.join(out, "report.txt"))
    return 0 if all(v.startswith("OK") for _, v in summary) else 1


if __name__ == "__main__":
    sys.exit(main())
