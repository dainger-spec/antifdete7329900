#!/usr/bin/env python3
"""Round 2: per state and variant, the marks round 1 found, against the HID route (a real mouse):
pointer moves seen, mousedown's buttons and pointerdown's pressure, the wheel's timeStamp and
screen coordinates, document.hasFocus() at the clicks and keys, the typed text, and whether every
event's screenX - clientX agrees (one window, one offset)."""
import json
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.startswith("RUN "):
        if line.startswith(("MACHINE", "DONE", "TIMEOUT", "NOTE")):
            print(line)
        continue
    _, state, variant, payload = line.split(" ", 3)
    run = json.loads(payload)
    if "error" in run:
        print(f"{state:9} {variant:8} error {run['error']}")
        continue
    ev = run["page"]["events"]
    of = lambda t: [e for e in ev if e["type"] == t]
    offsets = sorted({(round(e["screenX"] - e["clientX"]), round(e["screenY"] - e["clientY"])) for e in ev if "screenX" in e})
    print(f"{state:9} {variant:8} moves {len(of('mousemove'))} "
          f"down.buttons {[e.get('buttons') for e in of('mousedown')]} pdown.pressure {[e.get('pressure') for e in of('pointerdown')]} "
          f"wheel.t {[e['t'] for e in of('wheel')]} wheel.screen {sorted({(e['screenX'], e['screenY']) for e in of('wheel')})} "
          f"focus@click {[e['hasFocus'] for e in of('click')]} focus@key {[e['hasFocus'] for e in of('keydown')]} "
          f"field {run['page']['field']!r} offsets {offsets} vis {run['page']['visibility']} state {run['before']}")
