#!/usr/bin/env python3
"""Reads probe.swift's lines and says, per state and route, what the page saw: which events came,
whether every one was trusted, document.hasFocus() at the clicks and keys, the user activation,
whether the field took the focus and the typed text, the scroll, and the window's coordinates
against the events' (screenX - clientX), set against the HID route of the key state (the
reference: what the window server makes of a real mouse and keyboard).

    python3 measure/automation_input/analyse.py probe.txt
"""
import collections
import json
import sys

ORDER = ["key", "nonkey", "offscreen", "inactive"]
runs = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("RUN "):
        _, state, route, payload = line.split(" ", 3)
        try:
            runs[(state, route)] = json.loads(payload)
        except json.JSONDecodeError as error:
            runs[(state, route)] = {"error": f"unreadable: {error}"}
    elif line.startswith(("MACHINE", "DONE", "TIMEOUT")):
        print(line)


def summary(run):
    page = run.get("page") or {}
    events = page.get("events") or []
    counts = collections.Counter(e["type"] for e in events)
    untrusted = sorted({e["type"] for e in events if not e.get("trusted")})
    at = lambda t: [e for e in events if e["type"] == t]
    clicks = at("click")
    keys = at("keydown")
    offsets = sorted({(round(e["screenX"] - e["clientX"]), round(e["screenY"] - e["clientY"])) for e in events if "screenX" in e and e["type"] in ("mousemove", "mousedown", "click")})
    return {
        "events": dict(sorted(counts.items())),
        "untrusted": untrusted,
        "focusAtClick": [c["hasFocus"] for c in clicks],
        "focusAtKey": [k["hasFocus"] for k in keys],
        "activationAfter": page.get("activation"),
        "active": page.get("active"), "field": page.get("field"), "scrollY": page.get("scrollY"),
        "visibility": page.get("visibility"), "win": page.get("win"), "screenOffset": offsets,
        "pointerTypes": sorted({e.get("pointerType") for e in events if e.get("pointerType") is not None}),
        "keyFields": [(k.get("key"), k.get("code"), k.get("keyCode"), k.get("location")) for k in keys],
        "before": run.get("before"), "after": run.get("after"),
    }


ref = summary(runs[("key", "hid")]) if ("key", "hid") in runs else None
for state in ORDER:
    for route in ["window", "view", "quartz", "pid", "hid"]:
        run = runs.get((state, route))
        if run is None:
            print(f"== {state:9} {route:6}: no run")
            continue
        if "error" in run:
            print(f"== {state:9} {route:6}: {run['error']}")
            continue
        s = summary(run)
        print(f"== {state:9} {route:6}: {json.dumps(s, ensure_ascii=False)}")
        if ref and (state, route) != ("key", "hid"):
            missing = sorted(set(ref["events"]) - set(s["events"]))
            extra = sorted(set(s["events"]) - set(ref["events"]))
            print(f"   vs key/hid: missing {missing}, extra {extra}")
