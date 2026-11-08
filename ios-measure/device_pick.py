#!/usr/bin/env python3
"""Which device run_device.sh installs on: a real, paired iPhone — never a simulator.

`xcrun devicectl list devices` lists simulators too, with platform iOS (the owner, 8 November: with
simulators running, the script picked "Profile 18" and failed with "The capability "Install
Application" is not supported by this device"). A device counts only if devicectl calls it
physical (hardwareProperties.reality) and it is paired; DEVICE=<name, UDID or identifier> picks
one of several, or one the filter would not take.

    python3 ios-measure/device_pick.py devices.json [DEVICE]
    -> prints "<identifier> <udid> <transport> <developer mode> <name>", or explains and exits 1
"""
import json
import sys


def candidates(data):
    for d in data.get("result", {}).get("devices", []):
        hw = d.get("hardwareProperties", {})
        conn = d.get("connectionProperties", {})
        props = d.get("deviceProperties", {})
        yield {
            "identifier": d.get("identifier", ""),
            "udid": hw.get("udid") or "-",
            "name": props.get("name") or hw.get("marketingName") or "?",
            "platform": hw.get("platform", ""),
            "reality": hw.get("reality", ""),
            "pairing": conn.get("pairingState", ""),
            "tunnel": conn.get("tunnelState", ""),
            "transport": conn.get("transportType") or "-",
            "devmode": props.get("developerModeStatus") or "-",
        }


def real(device):
    return (device["platform"] == "iOS" and device["reality"] == "physical"
            and device["pairing"] == "paired" and device["tunnel"] != "unavailable")


def pick(data, wanted=""):
    every = list(candidates(data))
    if wanted:
        w = wanted.lower()
        hits = [d for d in every if w in (d["identifier"].lower(), d["udid"].lower(), d["name"].lower())]
        if len(hits) == 1:
            return hits[0], None
        return None, f"DEVICE={wanted}: {len(hits)} devices match it"
    phones = [d for d in every if real(d)]
    if len(phones) == 1:
        return phones[0], None
    if not phones:
        return None, "no real, paired iPhone (connect it, unlock it, tap Trust; pair it in Device Hub)"
    wired = [d for d in phones if d["transport"] == "wired"]
    if len(wired) == 1:
        return wired[0], None
    return None, f"{len(phones)} iPhones: say which one with DEVICE=<name or UDID>"


def main():
    data = json.load(open(sys.argv[1]))
    wanted = sys.argv[2] if len(sys.argv) > 2 else ""
    device, problem = pick(data, wanted)
    if problem:
        print(problem, file=sys.stderr)
        for d in candidates(data):
            print(f"  {d['name']!r}: {d['platform']} {d['reality'] or '?'}, {d['pairing'] or '?'}, "
                  f"tunnel {d['tunnel'] or '?'}, {d['transport']}, Developer Mode {d['devmode']}, UDID {d['udid']}",
                  file=sys.stderr)
        sys.exit(1)
    print(device["identifier"], device["udid"], device["transport"], device["devmode"], device["name"].replace(" ", "_"))


if __name__ == "__main__":
    main()
