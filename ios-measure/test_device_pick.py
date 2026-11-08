#!/usr/bin/env python3
"""device_pick.py on the owner's case: a paired iPhone and running simulators, all "iOS" to
devicectl. The rule run_device.sh had (the first iOS device whose tunnel is not unavailable) must
pick the simulator here — the fixture reproduces the bug — and device_pick.py the iPhone.

    python3 ios-measure/test_device_pick.py [devices.json measured on a runner, simulators booted]
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from device_pick import pick  # noqa: E402


def device(name, reality, pairing="paired", tunnel="connected", transport="wired", udid="00008110-000A1B2C3D4E5F6A", devmode="disabled"):
    return {"identifier": f"ID-{name}", "deviceProperties": {"name": name, "developerModeStatus": devmode},
            "hardwareProperties": {"platform": "iOS", "reality": reality, "udid": udid},
            "connectionProperties": {"pairingState": pairing, "tunnelState": tunnel, "transportType": transport}}


def old_rule(data):
    for d in data["result"]["devices"]:
        if d.get("hardwareProperties", {}).get("platform") == "iOS" and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
            return d["deviceProperties"]["name"]


failures = 0


def check(what, ok):
    global failures
    print(("ok    " if ok else "FAIL  ") + what)
    failures += 0 if ok else 1


# The owner's list on 8 November (devices.json of their q1-q3 runs), field by field, identifiers
# replaced: simulators are "simulated", paired, tunnel "disconnected", transport "sameMachine".
owner = {"result": {"devices": [
    device("Profile 18", "simulated", tunnel="disconnected", transport="sameMachine", udid="A1B2C3D4-0000-0000-0000-000000000018", devmode=None),
    device("Profile 24", "simulated", tunnel="disconnected", transport="sameMachine", udid="A1B2C3D4-0000-0000-0000-000000000024", devmode=None),
    device("iPad Pro 13-inch (M5)", "simulated", tunnel="disconnected", transport="sameMachine", udid="A1B2C3D4-0000-0000-0000-0000000000AD", devmode=None),
    device("iPhone владельца", "physical", devmode="enabled"),
]}}
check("the old rule picks the simulator in the owner's case (the bug, reproduced)", old_rule(owner) == "Profile 18")
picked, problem = pick(owner)
check("device_pick picks the iPhone", picked is not None and picked["name"] == "iPhone владельца")
check("DEVICE= by name picks it too", pick(owner, "iphone владельца")[0]["name"] == "iPhone владельца")
check("DEVICE= by UDID", pick(owner, "00008110-000A1B2C3D4E5F6A")[0]["name"] == "iPhone владельца")
check("simulators only: nothing is picked", pick({"result": {"devices": owner["result"]["devices"][:2]}})[0] is None)
unpaired = {"result": {"devices": [device("iPhone", "physical", pairing="unpaired")]}}
check("an iPhone not paired is not picked", pick(unpaired)[0] is None)
two = {"result": {"devices": [device("A", "physical", transport="localNetwork", udid="1"), device("B", "physical", udid="2")]}}
check("two iPhones: the one on the cable", pick(two)[0]["name"] == "B")

# What a runner measured: devicectl's list with simulators booted. Nothing there is a real iPhone.
if len(sys.argv) > 1:
    measured = json.load(open(sys.argv[1]))
    names = [(d.get("deviceProperties", {}).get("name"), d.get("hardwareProperties", {}).get("reality"))
             for d in measured.get("result", {}).get("devices", [])]
    print("measured list:", names)
    check("on the runner's list (simulators only) device_pick picks nothing", pick(measured)[0] is None)

sys.exit(1 if failures else 0)
