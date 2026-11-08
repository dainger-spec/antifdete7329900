#!/usr/bin/env python3
"""Is the built app the one run_device.sh is about to install and launch?

The owner's run on 8 November: Info.plist said io.lumenbrowser.measure while the build set
PRODUCT_BUNDLE_IDENTIFIER to io.lumenbrowser.measure.<team>, so the signature's application
identifier and the bundle's own disagreed — "is not installed" on launch, then
MismatchedApplicationIdentifierEntitlement on the next install. This compares the bundle's
CFBundleIdentifier, and the signature's application-identifier when the app is signed, with the
identifier the script will launch.

    python3 ios-measure/check_app.py <Lumen.app> <bundle id>   -> exit 0, or 1 saying what differs
"""
import plistlib
import subprocess
import sys


def entitlement_app_id(app):
    try:
        out = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", app],
                             capture_output=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    start = out.find(b"<?xml")
    if start < 0:
        return None
    try:
        return plistlib.loads(out[start:]).get("application-identifier")
    except Exception:
        return None


def main():
    app, wanted = sys.argv[1], sys.argv[2]
    with open(f"{app}/Info.plist", "rb") as f:
        info = plistlib.load(f)
    problems = []
    bundle = info.get("CFBundleIdentifier")
    if bundle != wanted:
        problems.append(f"Info.plist says CFBundleIdentifier {bundle!r}, the script would launch {wanted!r}")
    signed = entitlement_app_id(app)
    if signed is not None and signed.split(".", 1)[-1] != wanted:
        problems.append(f"the signature's application-identifier is {signed!r}, the script would launch {wanted!r}")
    if problems:
        print("THE BUILT APP IS NOT THE ONE TO LAUNCH: " + "; ".join(problems), file=sys.stderr)
        sys.exit(1)
    print(f"the built app is {wanted}" + (f" (signed as {signed})" if signed else " (not signed)"))


if __name__ == "__main__":
    main()
