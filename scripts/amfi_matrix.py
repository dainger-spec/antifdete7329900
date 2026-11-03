#!/usr/bin/env python3
"""Which signature the kernel lets an NE=1 build start with, on this Mac — a measurement, the owner's
Mac only (CI has no Developer ID, and the kernel lets no ad hoc signature carry these rights).

On 3 November 0.1.1, NE=1, signed with Developer ID and notarized, was killed at its start on the
owner's Mac (macOS 27.0.1, 26A434):

    AMFI: When validating …/Lumen.app/Contents/MacOS/Lumen:
      Hardened Runtime relaxation entitlements disallowed on System Extensions
    AMFI: hook..execve() killing env (pid …): Attempt to execute completely unsigned code

    python3 scripts/amfi_matrix.py --app build/release/app/Lumen.app \\
        --identity "Developer ID Application: <name> (<TEAM_ID>)" [--out build/amfi-matrix] \\
        [--notary-profile lumen-notary]

It works on copies of the app release.sh signed, each signed again with one thing changed: never the
app itself, nothing installed, no setting changed, nothing sent anywhere (but to Apple's timestamp
server, and to its notary service with --notary-profile). For each copy:

  * does the kernel let the app's executable start — `Lumen --keychain-probe`, which answers on one
    line and ends;
  * does it let the profile's executable start and load Safari's frameworks — `LumenProfile
    --check-safari-chrome`, as release.sh's step 2b runs it (Safari's code runs only there:
    SafariChromeHost.prepareForChildProcess);
  * where both start: the release check — `Lumen --release-check`, a profile in a process of its own
    in Safari's window, and the keychain between profiles;

and every line the kernel, amfid and syspolicyd wrote about it while it ran (AMFI, ASP,
mac_vnode_check_signature, and the sandbox's refusals of securityd), with what each executable was
signed with.

The copies — what the app's executable (Contents/MacOS/Lumen) is signed with; LumenProfile, the
helper and the extension stay as release.sh signed them:

  shipped                       the app as it is: its signature, notarization and staple
  resigned                      signed again with the same entitlements — the control: signing
                                again must change nothing, or every other copy says nothing
  app-no-dlv                    without com.apple.security.cs.disable-library-validation
  app-jit                       without it, with com.apple.security.cs.allow-jit
  app-unsigned-memory           without it, with com.apple.security.cs.allow-unsigned-executable-memory
  app-dyld-env                  without it, with com.apple.security.cs.allow-dyld-environment-variables
  app-dlv-no-install            with it, without com.apple.developer.system-extension.install
  app-dlv-no-provider           with it, without com.apple.developer.networking.networkextension
  app-dlv-neither               with it, without either of those two
  bundle-no-extension           as shipped, with Contents/Library/SystemExtensions taken out
  bundle-no-extension-neither   with it, without either right, and without the extension

Writes <out>/report.md — send it back — and <out>/report.json. codesign may ask once for the Developer
ID key in the login keychain: Always Allow. Without --notary-profile the copies signed again are not
notarized; that changes nothing for a copy that is not quarantined, which `resigned` shows: when it
does not end as `shipped` does, run again with --notary-profile (each copy then takes a few minutes).
"""
import argparse
import copy
import datetime
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time

DLV = "com.apple.security.cs.disable-library-validation"
JIT = "com.apple.security.cs.allow-jit"
UNSIGNED_MEMORY = "com.apple.security.cs.allow-unsigned-executable-memory"
DYLD_ENV = "com.apple.security.cs.allow-dyld-environment-variables"
INSTALL = "com.apple.developer.system-extension.install"
PROVIDER = "com.apple.developer.networking.networkextension"
RELAXATIONS = [DLV, JIT, UNSIGNED_MEMORY, DYLD_ENV, "com.apple.security.cs.disable-executable-page-protection"]
# What the kernel's and the system policy's lines about a start contain.
POLICY_WORDS = ["AMFI", "ASP:", "mac_vnode_check_signature", "code signature", "Security policy"]


def run(command, timeout=None, environment=None):
    """(status, output); status is "killed" for SIGKILL, "timeout", or the exit status."""
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=environment)
    except subprocess.TimeoutExpired as expired:
        output = (expired.stdout or b"") if isinstance(expired.stdout, bytes) else (expired.stdout or "")
        return "timeout", output if isinstance(output, str) else output.decode("utf-8", "replace")
    except OSError as error:
        return f"could not start ({error.strerror})", ""
    status = done.returncode
    if status == -9:
        status = "killed (SIGKILL, 137 in a shell)"
    elif status < 0:
        status = f"killed by signal {-status}"
    return status, done.stdout + done.stderr


def entitlements(path):
    out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", path], capture_output=True).stdout
    try:
        return plistlib.loads(out) if out.strip() else {}
    except Exception:
        return {"unreadable": True}


def kernel_lines(start, end, extra_words=()):
    """What the kernel, amfid and syspolicyd said between `start` and `end` about code signing and policy."""
    since = datetime.datetime.fromtimestamp(start - 1).strftime("%Y-%m-%d %H:%M:%S")
    until = datetime.datetime.fromtimestamp(end + 3).strftime("%Y-%m-%d %H:%M:%S")
    _, text = run(["log", "show", "--style", "compact", "--start", since, "--end", until, "--predicate",
                   'process == "kernel" OR process == "amfid" OR process == "syspolicyd"'], timeout=120)
    words = POLICY_WORDS + list(extra_words)
    return [line.strip() for line in text.splitlines() if any(word in line for word in words)][:40]


def describe(ents):
    """The rights and relaxations that matter here, in a few words."""
    held = [key.rsplit(".", 1)[-1] for key in RELAXATIONS if ents.get(key)]
    parts = ["relaxations: " + (", ".join(held) if held else "none")]
    parts.append("system-extension.install: " + ("yes" if ents.get(INSTALL) else "no"))
    provider = ents.get(PROVIDER)
    parts.append("networkextension: " + (", ".join(provider) if provider else "no"))
    return "; ".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="the NE=1 Lumen.app release.sh signed")
    parser.add_argument("--identity", required=True, help='"Developer ID Application: <name> (<TEAM_ID>)"')
    parser.add_argument("--out", default="build/amfi-matrix")
    parser.add_argument("--notary-profile", help="notarize and staple every copy signed again (slow)")
    parser.add_argument("--only", help="a comma-separated list of copies to make")
    arguments = parser.parse_args()

    app = os.path.abspath(arguments.app)
    out = os.path.abspath(arguments.out)
    if not os.path.isdir(app):
        sys.exit(f"no app at {app}")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id = info["CFBundleIdentifier"]
    executable = info["CFBundleExecutable"]
    shipped = entitlements(app)
    profile_ents = entitlements(os.path.join(app, "Contents", "MacOS", "LumenProfile"))
    extensions = [name for name in os.listdir(os.path.join(app, "Contents", "Library", "SystemExtensions"))
                  if name.endswith(".systemextension")] if os.path.isdir(os.path.join(app, "Contents", "Library", "SystemExtensions")) else []
    _, system = run(["sw_vers"])
    _, model = run(["sysctl", "-n", "hw.model"])
    print(f"this Mac: {' '.join(system.split())}, {model.strip()}", flush=True)
    print(f"the app: {app} ({bundle_id} {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})); "
          f"its executable: {describe(shipped)}; LumenProfile: {describe(profile_ents)}; extension: {', '.join(extensions) or 'none'}",
          flush=True)
    if not shipped.get(PROVIDER) and not shipped.get(INSTALL):
        print("note: this app's executable holds neither of the network guard's rights: is it an NE=1 build?", flush=True)

    def without(*keys, adding=()):
        changed = copy.deepcopy(shipped)
        for key in keys:
            changed.pop(key, None)
        for key in adding:
            changed[key] = True
        return changed

    copies = [
        ("shipped", None, False),
        ("resigned", copy.deepcopy(shipped), False),
        ("app-no-dlv", without(DLV), False),
        ("app-jit", without(DLV, adding=[JIT]), False),
        ("app-unsigned-memory", without(DLV, adding=[UNSIGNED_MEMORY]), False),
        ("app-dyld-env", without(DLV, adding=[DYLD_ENV]), False),
        ("app-dlv-no-install", without(INSTALL), False),
        ("app-dlv-no-provider", without(PROVIDER), False),
        ("app-dlv-neither", without(INSTALL, PROVIDER), False),
        ("bundle-no-extension", copy.deepcopy(shipped), True),
        ("bundle-no-extension-neither", without(INSTALL, PROVIDER), True),
    ]
    if arguments.only:
        wanted = set(arguments.only.split(","))
        copies = [entry for entry in copies if entry[0] in wanted]

    environment = {key: value for key, value in os.environ.items() if key not in ("PB_PROFILE_PROCESS", "PB_SAFARI_CHROME")}
    results = []
    for name, ents, drop_extension in copies:
        print(f"\n== {name}", flush=True)
        folder = os.path.join(out, name)
        os.makedirs(folder)
        target = os.path.join(folder, "Lumen.app")
        status, output = run(["ditto", app, target])
        result = {"copy": name, "signing": "as release.sh signed it" if ents is None else "signed again"}
        if status != 0:
            result["error"] = f"ditto: {output.strip()[:300]}"
            results.append(result)
            continue
        if drop_extension:
            shutil.rmtree(os.path.join(target, "Contents", "Library", "SystemExtensions"), ignore_errors=True)
        if ents is not None:
            ents_path = os.path.join(folder, "app.entitlements")
            with open(ents_path, "wb") as handle:
                plistlib.dump(ents, handle)
            base = ["codesign", "--force", "--options", "runtime", "--identifier", bundle_id, "--entitlements", ents_path,
                    "--sign", arguments.identity]
            status, output = run(base[:4] + ["--timestamp"] + base[4:] + [target], timeout=180)
            result["timestamp"] = "secure"
            if status != 0:
                # Offline, or the timestamp server did not answer: without one (it does not decide a start).
                status, output = run(base[:4] + ["--timestamp=none"] + base[4:] + [target], timeout=180)
                result["timestamp"] = "none"
            if status != 0:
                result["error"] = f"codesign: {output.strip()[:400]}"
                results.append(result)
                print(f"  could not sign: {output.strip()[:200]}", flush=True)
                continue
            if arguments.notary_profile:
                archive = os.path.join(folder, "notarize.zip")
                run(["ditto", "-c", "-k", "--keepParent", target, archive])
                status, output = run(["xcrun", "notarytool", "submit", archive, "--keychain-profile", arguments.notary_profile, "--wait"],
                                     timeout=3600)
                os.remove(archive)
                stapled, _ = run(["xcrun", "stapler", "staple", target], timeout=300)
                result["notarized"] = "Accepted" in output and stapled == 0
        signed = entitlements(target)
        result["app_entitlements"] = describe(signed)
        result["extension_in_bundle"] = os.path.isdir(os.path.join(target, "Contents", "Library", "SystemExtensions"))
        verify_status, verify_output = run(["codesign", "--verify", "--strict", "--deep", target], timeout=180)
        result["codesign_verify"] = "valid" if verify_status == 0 else verify_output.strip()[:300]
        _, assessment = run(["spctl", "--assess", "--type", "execute", "--verbose=2", target], timeout=120)
        result["spctl"] = " ".join(assessment.split())[:200]

        # The app's executable: does the kernel let it start?
        started = time.time()
        status, output = run([os.path.join(target, "Contents", "MacOS", executable), "--keychain-probe", "amfi-matrix"], timeout=60,
                             environment=environment)
        result["app_start"] = {"status": status, "answered": "KEYCHAIN-PROBE {" in output,
                               "kernel": kernel_lines(started, time.time())}
        print(f"  Lumen: {status}, {'answered' if result['app_start']['answered'] else 'no answer'}", flush=True)
        for line in result["app_start"]["kernel"][:6]:
            print("    " + line[:300], flush=True)

        # The profile's executable, where Safari's frameworks load.
        started = time.time()
        status, output = run([os.path.join(target, "Contents", "MacOS", "LumenProfile"), "--check-safari-chrome"], timeout=300,
                             environment=environment)
        result["profile_start"] = {"status": status,
                                   "safari_lines": [line for line in output.splitlines() if line.startswith(("SAFARI-CHROME", "MISSING"))][:10],
                                   "kernel": kernel_lines(started, time.time(), extra_words=("SecurityServer", "securityd"))}
        print(f"  LumenProfile --check-safari-chrome: {status}", flush=True)
        for line in result["profile_start"]["safari_lines"][:3] + result["profile_start"]["kernel"][:6]:
            print("    " + line[:300], flush=True)

        # Both start: the product's own check.
        if result["app_start"]["answered"] and result["profile_start"]["status"] == 0:
            started = time.time()
            status, output = run([os.path.join(target, "Contents", "MacOS", executable), "--release-check"], timeout=420,
                                 environment=environment)
            result["release_check"] = {"status": status,
                                       "lines": [line for line in output.splitlines() if line.startswith("RELEASE-CHECK")][:20],
                                       "kernel": kernel_lines(started, time.time())}
            print(f"  Lumen --release-check: {status}", flush=True)
            for line in result["release_check"]["lines"]:
                print("    " + line[:300], flush=True)
        results.append(result)

    def start_word(entry, key):
        value = entry.get(key)
        if not value:
            return "—"
        if key == "app_start":
            return "starts" if value["answered"] else str(value["status"])
        return "starts, Safari loads" if value["status"] == 0 else str(value["status"])

    lines = [f"# AMFI matrix, {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}", "",
             f"This Mac: {' '.join(system.split())}, {model.strip()}", "",
             f"The app: `{app}` — {bundle_id} {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})", "",
             f"LumenProfile (unchanged in every copy): {describe(profile_ents)}", "",
             "| copy | the app's executable signed with | extension in the bundle | Lumen | LumenProfile | release check |",
             "|---|---|---|---|---|---|"]
    for entry in results:
        if "error" in entry:
            lines.append(f"| {entry['copy']} | {entry['error']} | | | | |")
            continue
        check = entry.get("release_check")
        verdict = "—" if not check else ("PASS" if check["status"] == 0 else f"FAIL ({check['status']})")
        lines.append(f"| {entry['copy']} | {entry['app_entitlements']} | {'yes' if entry['extension_in_bundle'] else 'no'} | "
                     f"{start_word(entry, 'app_start')} | {start_word(entry, 'profile_start')} | {verdict} |")
    shipped_entry = next((entry for entry in results if entry["copy"] == "shipped"), None)
    resigned_entry = next((entry for entry in results if entry["copy"] == "resigned"), None)
    if shipped_entry and resigned_entry and "app_start" in shipped_entry and "app_start" in resigned_entry:
        same = shipped_entry["app_start"]["answered"] == resigned_entry["app_start"]["answered"]
        lines += ["", "The control: " + ("signing again changed nothing (`resigned` ends as `shipped` does)." if same else
                  "**signing again changed the outcome** — run again with `--notary-profile lumen-notary`; this table says nothing until then.")]
    lines += ["", "## What the kernel and the system's policy said", ""]
    for entry in results:
        lines.append(f"### {entry['copy']}")
        for key in ("app_start", "profile_start", "release_check"):
            part = entry.get(key)
            if not part:
                continue
            lines.append(f"- {key}: {part['status']}")
            for line in part.get("kernel", [])[:12]:
                lines.append(f"  - `{line[:400]}`")
            for line in part.get("lines", part.get("safari_lines", []))[:12]:
                lines.append(f"  - `{line[:300]}`")
        lines.append(f"- codesign --verify: {entry.get('codesign_verify', '—')}; spctl: {entry.get('spctl', '—')}"
                     + (f"; notarized: {entry['notarized']}" if "notarized" in entry else ""))
        lines.append("")
    with open(os.path.join(out, "report.md"), "w") as handle:
        handle.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "report.json"), "w") as handle:
        json.dump({"mac": " ".join(system.split()), "model": model.strip(), "app": app, "results": results}, handle, indent=1)
    print(f"\nreport: {os.path.join(out, 'report.md')}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
