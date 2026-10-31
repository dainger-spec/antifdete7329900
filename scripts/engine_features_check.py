#!/usr/bin/env python3
"""WebKit's features in a profile's web views as Safari has them (SafariEngineFeatures), checked.

    scripts/engine_features_check.py --app build/unsandboxed/PrivacyBrowser.app --out build/engine-features \
        [--copy-sdk 14.0] [--title "WebKit's features"] [--report-only]

For the app as built, and with --copy-sdk a copy of it whose executable declares that SDK (made as
scripts/aia_variants.py makes them; the releases, built with Xcode 27, declare 14.0), the app's
`--sdk-check --features` runs three ways: with WebKit's features as a profile's web views have them
(`--as-profile`), as the build has them, and with every SDK behavior on, as Safari has them
(`--everything`). On a macOS the table was measured on, the check fails when

  * a feature whose default the SDK's behaviors change is not set by the table as Safari has it,
    or the table sets one otherwise than Safari has it;
  * a feature of the table is not as the table says in the profile's web view;
  * a page in the profile's web view differs from one with every behavior on: the window's own
    names, typeof trustedTypes and MutationEvent, a DOMNodeInserted listener, `new FontFaceSet([])`.

On another macOS nothing is set (SafariEngineFeatures), and the check says what differs and passes.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aia_variants import BINARY, copy_declaring, declared_sdk  # noqa: E402

PAGE_KEYS = ("trustedTypes", "MutationEvent", "mutationEventsFired", "fontFaceSetConstructor")


def run(app, flags):
    """`--sdk-check --features` with `flags`: the features (default and here), the table, the page."""
    try:
        output = subprocess.run([os.path.join(app, BINARY), "--sdk-check", "--features", *flags],
                                capture_output=True, text=True, timeout=90).stdout
    except subprocess.TimeoutExpired as expired:
        output = expired.stdout if isinstance(expired.stdout, str) else (expired.stdout or b"").decode(errors="replace")
    seen = {"defaults": {}, "here": {}, "table": {}, "measured": None, "page": None, "names": None, "output": output}
    for line in output.splitlines():
        if line.startswith("SDK-CHECK feature "):
            parts = line.split()
            # SDK-CHECK feature <key> default <bool> here <bool|?>
            if len(parts) == 7:
                seen["defaults"][parts[2]] = parts[4] == "true"
                seen["here"][parts[2]] = None if parts[6] == "?" else parts[6] == "true"
        elif line.startswith("SDK-CHECK as Safari: "):
            key, value = line[len("SDK-CHECK as Safari: "):].split()
            seen["table"][key] = value == "true"
        elif line.startswith("SDK-CHECK as a profile: "):
            seen["measured"] = ": yes" in line
        elif line.startswith("SDK-CHECK the page: "):
            try:
                seen["page"] = json.loads(line[len("SDK-CHECK the page: "):])
            except ValueError:
                seen["page"] = None
        elif line.startswith("SDK-CHECK window names: "):
            seen["names"] = set(name for name in line[len("SDK-CHECK window names: "):].split(",") if name)
    return seen


def check(name, slug, app, out):
    """The three runs of one build; returns (failures, notes)."""
    profile = run(app, ["--as-profile"])
    built = run(app, [])
    every = run(app, ["--everything"])
    for label, seen in (("as-a-profile", profile), ("as-built", built), ("everything", every)):
        with open(os.path.join(out, f"{slug}-{label}.txt"), "w") as handle:
            handle.write(seen["output"])
    failures, notes = [], []
    if not (profile["defaults"] and built["defaults"] and every["defaults"]):
        return [f"{name}: a run listed no features (see {out})"], notes
    if profile["page"] is None or every["page"] is None or profile["names"] is None or every["names"] is None:
        return [f"{name}: a run did not report its page (see {out})"], notes
    table, measured = profile["table"], profile["measured"]
    changed = {key: every["defaults"][key] for key, value in built["defaults"].items()
               if key in every["defaults"] and every["defaults"][key] != value}
    notes.append(f"{name}: the SDK's behaviors change {len(changed)} feature(s): "
                 + (", ".join(f"{key} → {'on' if value else 'off'}" for key, value in sorted(changed.items())) or "none"))
    unset = sorted(key for key, value in changed.items() if table.get(key) != value)
    otherwise = sorted(key for key, value in table.items() if key in every["defaults"] and every["defaults"][key] != value)
    not_here = sorted(key for key, value in table.items() if profile["here"].get(key) != value)
    page = {key: (profile["page"].get(key), every["page"].get(key)) for key in PAGE_KEYS
            if profile["page"].get(key) != every["page"].get(key)}
    only_profile = sorted(profile["names"] - every["names"])
    only_every = sorted(every["names"] - profile["names"])
    found = []
    if unset:
        found.append(f"changed by the SDK's behaviors and not set as Safari has them: {', '.join(unset)}")
    if otherwise:
        found.append(f"set otherwise than Safari has them: {', '.join(otherwise)}")
    if measured and not_here:
        found.append(f"not as the table says in the profile's web view: {', '.join(not_here)}")
    if page:
        found.append("the page differs from one with every behavior on: "
                     + "; ".join(f"{key} {mine!r} against {theirs!r}" for key, (mine, theirs) in page.items()))
    if only_profile or only_every:
        found.append(f"the window's names differ from those with every behavior on: only in the profile's {only_profile[:40]}, "
                     f"only with every behavior on {only_every[:40]}")
    if not found:
        notes.append(f"{name}: a page in the profile's web view is as with every behavior on — "
                     f"{len(profile['names'])} window names, {json.dumps({key: profile['page'].get(key) for key in PAGE_KEYS})}")
    elif measured:
        failures += [f"{name}: {text}" for text in found]
    else:
        notes += [f"{name} (not a macOS the table was measured on; nothing is set): {text}" for text in found]
    return failures, notes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--copy-sdk", help="also check a copy whose executable declares this SDK")
    parser.add_argument("--title", default="WebKit's features")
    parser.add_argument("--report-only", action="store_true", help="say what fails, but pass")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    out = os.path.abspath(args.out)
    _, sdk = declared_sdk(os.path.join(args.app, BINARY))
    builds = [(f"the build as made (sdk {sdk})", "as-made", args.app)]
    folder = None
    if args.copy_sdk:
        folder = tempfile.mkdtemp(prefix="pb-engine-features-")
        entitlements = os.path.join(out, "entitlements.plist")
        with open(entitlements, "wb") as handle:
            handle.write(subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", args.app],
                                        capture_output=True).stdout)
        copy = copy_declaring(args.app, args.copy_sdk, folder, entitlements)
        if copy:
            builds.append((f"a copy declaring sdk {args.copy_sdk}", f"sdk-{args.copy_sdk}", copy))
        else:
            print(f"::error title={args.title}::no copy declaring SDK {args.copy_sdk} could be made", flush=True)
            shutil.rmtree(folder, ignore_errors=True)
            return 0 if args.report_only else 1
    failures = []
    try:
        for name, slug, app in builds:
            found, notes = check(name, slug, app, out)
            failures += found
            for note in notes:
                print(f"ENGINE-FEATURES {note}", flush=True)
                print(f"::notice title={args.title}::{note}", flush=True)
    finally:
        if folder:
            shutil.rmtree(folder, ignore_errors=True)
    for failure in failures:
        print(f"ENGINE-FEATURES FAIL {failure}", flush=True)
        print(f"::{'warning' if args.report_only else 'error'} title={args.title}::{failure}", flush=True)
    if not failures:
        print("ENGINE-FEATURES a profile's web views have WebKit's features as Safari has them", flush=True)
    return 1 if failures and not args.report_only else 0


if __name__ == "__main__":
    sys.exit(main())
