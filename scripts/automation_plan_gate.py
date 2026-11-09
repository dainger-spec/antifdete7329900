#!/usr/bin/env python3
"""No release while the server signs no automation into the documents of rights.

    python3 scripts/automation_plan_gate.py [--vectors <entitlement-test-vectors.json>]

The whole automation API and every scenario run are the plan's (`features` names `automation` in the
document of rights: docs/AUTOMATION_API.md, "The plan"). The owner and the lead, 9 November:
automation is the trial's, Professional's and Team's; Personal has none. The server did not sign the
field yet (v2026.11.09.3), and an app with the gate, released against such a server, would refuse
the API to everyone — so no such release is made.

What this reads is the app's copy of the server's vectors (Tests/BrowserCoreTests/Fixtures/
entitlement-test-vectors.json, which the server's tests check is what its code produces). It passes
(exit 0) when the valid documents there show the decision: an active trial, an active Professional
and an active Team document each name `automation`; there is an active Personal document, and none
of them names it; there is an export-only document. Anything else is exit 1 with what is missing.
The signatures are not checked here: LicenseTests reads the same file with the app's verifier.

It says what the server's code produces, not what the live server runs: the copy is updated when the
server's release with the field is the one deployed (docs/AUTOMATION_API.md).
"""
import argparse
import base64
import json
import sys

DEFAULT = "Tests/BrowserCoreTests/Fixtures/entitlement-test-vectors.json"
OPEN = ("trial", "pro", "team")
TAG = "AUTOMATION-PLAN-GATE"


def documents(path):
    """(case name, plan, status, features or None) of every case the server says checks."""
    with open(path, encoding="utf-8") as file:
        vectors = json.load(file)
    found = []
    for case in vectors["cases"]:
        if case.get("verify") != "ok":
            continue
        envelope = json.loads(case["document"])
        payload = json.loads(base64.b64decode(envelope["payload"]))
        features = payload.get("features")
        if not (isinstance(features, list) and all(isinstance(name, str) for name in features)):
            features = None  # the app reads anything but a list of names as no features
        found.append((case["name"], payload.get("plan"), payload.get("status"), features))
    return found


def findings(found):
    missing = []
    for plan in OPEN:
        active = [f for name, p, status, f in found if p == plan and status == "active"]
        if not active:
            missing.append(f"no active {plan} document")
        elif not all(f is not None and "automation" in f for f in active):
            missing.append(f"an active {plan} document does not name automation")
    personal = [f for name, p, status, f in found if p == "personal" and status == "active"]
    if not personal:
        missing.append("no active personal document")
    elif any(f is not None and "automation" in f for f in personal):
        missing.append("an active personal document names automation")
    if not any(status == "export_only" for name, p, status, f in found):
        missing.append("no export-only document")
    return missing


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--vectors", default=DEFAULT)
    args = parser.parse_args()
    try:
        found = documents(args.vectors)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"{TAG} FAIL {args.vectors} could not be read as the server's vectors: {error}")
        return 1
    missing = findings(found)
    with_field = sum(1 for name, plan, status, f in found if f is not None)
    if missing:
        print(f"{TAG} FAIL the server's vectors do not show automation signed by plan "
              f"({len(found)} valid documents, {with_field} with `features`): " + "; ".join(missing))
        return 1
    print(f"{TAG} PASS the server's vectors sign automation into the trial, Professional and Team, "
          f"not into Personal ({len(found)} valid documents, {with_field} with `features`)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
