#!/usr/bin/env python3
"""From which SDK an app's executable declares does this Mac fetch a certificate's missing
intermediate outside a profile's proxy?

    python3 scripts/aia_variants.py --app build/unsandboxed/PrivacyBrowser.app \\
        --sdk "15.0,26.5,$(xcrun --show-sdk-version)" --out build/aia-variants --title "AIA variants"

WebKit turns some of its behaviors on only for an app whose executable declares a recent enough SDK
(WTF's computeSDKAlignedBehaviors), and every one with +[WKProcessPool _setLinkedOnOrAfterEverything]
(SDKBehaviors.swift). On macOS 27, with the switch (CI run 448) and with the executables declaring
macOS 27's SDK (run 450), the self-test's certificate check had this Mac resolve the AIA canary — the
address the self-test proxy's certificate names for its missing intermediate — outside the profile's
proxy; declaring 14.0 (runs 447 and 449) it did not. This runs the self-test's "certificates" group
alone (PB_SELFTEST_ONLY) under a packet capture with process names, once per variant:

  * the app as built (the SDK its executable declares);
  * the same with every behavior on (--sdk-everything);
  * a copy whose executable declares each SDK given (vtool; signed ad hoc with the app's
    entitlements): the versions WebKit gates its behaviors on tell which of them starts it, and
    26.5 is what a build made with Xcode 26 declares.

Each variant has a self-test proxy of its own, started with a tag of its own (selftest_proxy.py
--aia-tag): new certificates, naming `pbaiacanary<tag>` (loaded in a profile with the proxy) and
`pbaiacontrol<tag>` (the control: a profile without a proxy, for which the system does fetch on
macOS 27). A name already asked for can be answered from a cache: the first version of this script
used one name for every variant and, in run 450, saw neither name in any variant, the control
included. A variant whose control was not asked for cannot tell, and says so. A measurement: exit 0
always.
"""
import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = "Contents/MacOS/PrivacyBrowser"
PORTS = {"http": 18180, "socks": 18181, "tls-control": 18186, "canary": 18187}
LINE = re.compile(r"^(\d+\.\d+) \(([^)]*)\)")


def notice(title, text):
    print(f"::notice title={title}::{text[:900]}", flush=True)


def wait_for_port(port, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.5)
    return False


def declared_sdk(binary):
    shown = subprocess.run(["xcrun", "vtool", "-show-build", binary], capture_output=True, text=True).stdout
    values = dict(re.findall(r"^\s*(minos|sdk)\s+(\S+)", shown, re.M))
    return values.get("minos"), values.get("sdk")


def copy_declaring(app, sdk, folder, entitlements):
    """A copy of `app` in `folder` whose executable declares `sdk`, or None."""
    copy = os.path.join(folder, "PrivacyBrowser.app")
    shutil.copytree(app, copy, symlinks=True)
    binary = os.path.join(copy, BINARY)
    minos, _ = declared_sdk(binary)
    if not minos:
        return None
    done = subprocess.run(["xcrun", "vtool", "-set-build-version", "macos", minos, sdk, "-replace",
                           "-output", binary + ".declared", binary], capture_output=True, text=True)
    if done.returncode != 0:
        print(f"vtool: {done.stderr.strip()}", flush=True)
        return None
    os.replace(binary + ".declared", binary)
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--entitlements", entitlements,
                    "--sign", "-", copy], capture_output=True)
    return copy


def version_key(sdk):
    try:
        return tuple(int(part) for part in sdk.split("."))
    except (AttributeError, ValueError):
        return ()


def run_variant(index, app, extra, out, title):
    """The certificate check of `app`, with a proxy whose certificates name addresses of their own.
    Returns (tag, begin, end, self-test output)."""
    tag = f"v{index}{os.urandom(3).hex()}"
    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "selftest_proxy.py"),
                              "--http", str(PORTS["http"]), "--socks", str(PORTS["socks"]),
                              "--tls-control", str(PORTS["tls-control"]), "--canary", str(PORTS["canary"]),
                              "--aia-tag", tag],
                             stdout=open(os.path.join(out, f"proxy-{index}.txt"), "w"), stderr=subprocess.STDOUT)
    begin = time.time()
    try:
        if not (wait_for_port(PORTS["http"]) and wait_for_port(PORTS["tls-control"])):
            print(f"::warning title={title}::variant {index}: the self-test proxy did not start", flush=True)
            return tag, begin, time.time(), ""
        environment = dict(os.environ, PB_SELFTEST_ONLY="certificates",
                           PB_SELFTEST_HTTP_PROXY_PORT=str(PORTS["http"]),
                           PB_SELFTEST_TLS_CONTROL_PORT=str(PORTS["tls-control"]),
                           PB_SELFTEST_CANARY_PORT=str(PORTS["canary"]))
        try:
            result = subprocess.run([os.path.join(app, BINARY), "--self-test", *extra], env=environment,
                                    capture_output=True, text=True, timeout=240)
            output = result.stdout
        except subprocess.TimeoutExpired as expired:
            output = (expired.stdout or b"").decode(errors="replace") + "\n(timed out)"
        # A question can follow the check by a moment.
        time.sleep(4)
        return tag, begin, time.time(), output
    finally:
        proxy.kill()
        proxy.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--sdk", required=True, help="the SDKs the copies declare, comma-separated")
    parser.add_argument("--out", required=True)
    parser.add_argument("--title", default="AIA variants")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    out = os.path.abspath(args.out)
    entitlements = os.path.join(out, "entitlements.plist")
    with open(entitlements, "wb") as handle:
        handle.write(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", args.app],
                                    capture_output=True).stdout)

    capture_path = os.path.join(out, "capture.txt")
    capture = subprocess.Popen(["sudo", "tcpdump", "-i", "pktap,all", "-k", "NP", "-n", "-tt", "-l",
                                "not host 127.0.0.1 and not host ::1"],
                               stdout=open(capture_path, "w"), stderr=open(os.path.join(out, "tcpdump.err"), "w"))
    time.sleep(2)

    built_minos, built_sdk = declared_sdk(os.path.join(args.app, BINARY))
    variants = [("as built", None, []), ("as built, every behavior on", None, ["--sdk-everything"])]
    variants += [(f"declaring SDK {sdk}", sdk, []) for sdk in
                 [value.strip() for value in args.sdk.split(",") if value.strip()]]
    results = []
    for index, (name, sdk, extra) in enumerate(variants):
        folder = tempfile.mkdtemp(prefix="pb-aia-variant-")
        try:
            app, declared = args.app, (built_minos, built_sdk)
            if sdk:
                app = copy_declaring(args.app, sdk, folder, entitlements)
                if not app:
                    print(f"::warning title={args.title}::no copy declaring SDK {sdk}", flush=True)
                    continue
                declared = declared_sdk(os.path.join(app, BINARY))
            tag, begin, end, output = run_variant(index, app, extra, out, args.title)
        except Exception as error:  # noqa: BLE001 - one variant's failure leaves the others to measure
            print(f"::warning title={args.title}::{name}: {error!r}", flush=True)
            continue
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        with open(os.path.join(out, f"variant-{index}.txt"), "w") as handle:
            handle.write(output)
        results.append((name, declared, extra, tag, begin, end, output))
        time.sleep(2)

    subprocess.run(["sudo", "pkill", "-INT", "-f", "tcpdump -i pktap"], capture_output=True)
    time.sleep(2)
    with open(capture_path, errors="replace") as handle:
        lines = handle.read().splitlines()

    verdicts = []
    for name, (minos, sdk), extra, tag, begin, end, output in results:
        asked = {"canary": [], "control": []}
        for line in lines:
            match = LINE.match(line)
            if not match or "?" not in line:
                continue
            for kind in asked:
                if f"pbaia{kind}{tag}.leak.example.com" in line:
                    asked[kind].append(match.group(2))
        canary, control = asked["canary"], asked["control"]
        if canary:
            verdict = "LEAKS" + ("" if control else " (the control was not asked for)")
        elif control:
            verdict = "clean"
        else:
            verdict = "cannot tell: the control was not asked for"
        verdicts.append((name, sdk, extra, verdict))
        checks = [line for line in output.splitlines()
                  if line.startswith(("PASS certificates", "FAIL certificates", "SELFTEST", "INFO WebKit's behaviors",
                                      "INFO certificates"))]
        summary = (f"AIA-VARIANT {name} (declares minos {minos}, sdk {sdk}; names tagged {tag}): {verdict} — "
                   f"the canary asked of this Mac's resolver {len(canary)} time(s)"
                   f"{' by ' + '; '.join(sorted(set(canary))) if canary else ''}, "
                   f"the control {len(control)} time(s){' by ' + '; '.join(sorted(set(control))) if control else ''}")
        print(summary, flush=True)
        for check in checks:
            print("    " + check, flush=True)
        notice(args.title, summary)

    # The SDKs alone (no switch), ordered: the newest that stayed clean and the oldest that leaked.
    by_sdk = sorted(((version_key(sdk), sdk, verdict) for name, sdk, extra, verdict in verdicts
                     if not extra and sdk), key=lambda entry: entry[0])
    clean = [sdk for key, sdk, verdict in by_sdk if verdict == "clean"]
    leaking = [sdk for key, sdk, verdict in by_sdk if verdict.startswith("LEAKS")]
    unknown = [sdk for key, sdk, verdict in by_sdk if verdict.startswith("cannot")]
    notice(args.title, f"AIA-VARIANTS by SDK declared: clean {', '.join(clean) or 'none'}; "
                       f"leaks {', '.join(leaking) or 'none'}; cannot tell {', '.join(unknown) or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
