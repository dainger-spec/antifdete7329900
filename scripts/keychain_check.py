#!/usr/bin/env python3
"""What the app leaves in the account's keychain — a measurement, CI only:

    python3 scripts/keychain_check.py snapshot build/keychain/before.json
    ... the app runs: the release check of the dry run, the self-test of both builds, Safari's menu
        walked in a profile ...
    python3 scripts/keychain_check.py snapshot build/keychain/after.json
    python3 scripts/keychain_check.py compare build/keychain/before.json build/keychain/after.json

The app's own code keeps nothing in a keychain (no SecItem call), and every keychain write a
profile's process makes — Safari's code asking to keep its "Safari Defaults" — is refused for want
of an entitlement (errSecMissingEntitlement, -34018: the measurement of CI run 521). An item in a
keychain is tied to the app that made it: by its code signature in the account's login keychain, by
its application identifier (team ID + bundle ID) in the data-protection keychain. This says, run
after run, whether anything is there to be tied: every item of the account's default keychain that
is in the second snapshot and not in the first, by its attributes — class, service or server,
account, label, access group — never its secret (`security dump-keychain` without -d). The
data-protection keychain is not listed by `security`; there the -34018 refusals are the measurement.

A snapshot is only worth something if it can show an item: each one first adds an item of its own
(`security add-generic-password`), must find it in its listing, and deletes it again. One that could
not is SKIPPED, by name and in the job's summary, and `compare` fails: a listing that could not show
an item says nothing about what the app left. What the comparison finds is a warning, not a failure:
the system's own services keep items in the same keychain while the job runs, and an item does not
say which process made it.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid

ATTRIBUTES = ("svce", "srvr", "acct", "labl", "agrp", "ptcl", "path", "desc")
# `security dump-keychain` lines: 'class: "genp"', '    "svce"<blob>="service"', '    "acct"<blob>=<NULL>'.
CLASS = re.compile(r'^class: (?:"([^"]*)"|(0x[0-9A-Fa-f]+))')
ATTRIBUTE = re.compile(r'^\s+"([a-z]{4})"<[^>]+>=(.*)$')


def security(*arguments, timeout=60):
    """`security` with a deadline: a keychain that asks for a password never answers here."""
    try:
        result = subprocess.run(["security", *arguments], stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, errors="replace", timeout=timeout)
        return result.returncode, result.stdout, result.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, "", f"no answer in {timeout} s"
    except OSError as error:
        return -1, "", str(error)


def listing():
    """The default keychain's items, each a dict of its class and attributes."""
    status, output, error = security("dump-keychain")
    if status != 0:
        return None, error or f"security dump-keychain exited {status}"
    items, current = [], None
    for line in output.splitlines():
        match = CLASS.match(line)
        if match:
            current = {"class": match.group(1) or match.group(2)}
            items.append(current)
            continue
        match = ATTRIBUTE.match(line)
        if match and current is not None and match.group(1) in ATTRIBUTES:
            value = match.group(2).strip()
            current[match.group(1)] = None if value == "<NULL>" else value.strip('"')
    return items, None


def key(item):
    return json.dumps(item, sort_keys=True)


def snapshot(path):
    control = f"pb-keychain-control-{uuid.uuid4().hex[:12]}"
    status, _, error = security("add-generic-password", "-a", "pb-keychain-control", "-s", control, "-w", "control", "-U")
    added = status == 0
    items, listing_error = listing()
    seen = added and items is not None and any(item.get("svce") == control for item in items)
    if added:
        security("delete-generic-password", "-a", "pb-keychain-control", "-s", control)
        items = [item for item in (items or []) if item.get("svce") != control]
    _, keychain, _ = security("default-keychain")
    record = {
        "time": time.time(),
        "keychain": keychain.strip().strip('"'),
        "items": items if items is not None else [],
        "control_seen": seen,
        "why_not": None if seen else (listing_error if items is None else
                                      ("its control item could not be added: " + error) if not added else
                                      "its control item was added but is not in the listing"),
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(record, handle, indent=1)
    print(f"keychain snapshot {path}: {record['keychain']}, {len(record['items'])} items, "
          f"control {'seen' if seen else 'NOT seen: ' + record['why_not']}")
    return 0


def compare(before_path, after_path):
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = []
    # A snapshot not taken (a step before it failed) is a comparison not made, said as such.
    missing = [path for path in (before_path, after_path) if not os.path.exists(path)]
    if missing:
        for path in missing:
            print(f"::error title=keychain - not compared::no snapshot at {path} (a step before it failed or did not "
                  f"run): what the app left in the keychain was not measured")
        if summary:
            with open(summary, "a") as handle:
                handle.write("### Keychain: not compared — no snapshot at " + ", ".join(missing) + "\n")
        return 1
    with open(before_path) as handle:
        before = json.load(handle)
    with open(after_path) as handle:
        after = json.load(handle)
    blind = [(name, record["why_not"]) for name, record in (("before", before), ("after", after)) if not record["control_seen"]]
    if blind:
        for name, why in blind:
            print(f"::error title=keychain - SKIPPED::the keychain snapshot {name} the app ran could not show an item of "
                  f"its own ({why}): what the app left in the keychain was not measured")
        lines.append("### Keychain: SKIPPED — " + "; ".join(f"the snapshot {name}: {why}" for name, why in blind))
        status = 1
    else:
        known = {key(item) for item in before["items"]}
        new = [item for item in after["items"] if key(item) not in known]
        minutes = (after["time"] - before["time"]) / 60
        print(f"keychain {after['keychain']}: {len(before['items'])} items before the app ran, {len(after['items'])} "
              f"after ({minutes:.0f} minutes); new: {len(new)}")
        lines.append(f"### Keychain ({after['keychain']}): {len(before['items'])} items before, "
                     f"{len(after['items'])} after; {len(new)} new")
        for item in new:
            text = ", ".join(f"{name} {item[name]}" for name in ("class",) + ATTRIBUTES if item.get(name))
            print(f"::warning title=keychain - an item appeared while the app ran::{text}")
            lines.append(f"- {text}")
        status = 0
    if summary:
        with open(summary, "a") as handle:
            handle.write("\n".join(lines) + "\n")
    return status


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "snapshot":
        return snapshot(sys.argv[2])
    if len(sys.argv) == 4 and sys.argv[1] == "compare":
        return compare(sys.argv[2], sys.argv[3])
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
