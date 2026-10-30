#!/usr/bin/env python3
"""The app with many profiles, in numbers: `PrivacyBrowser --scale-check` (ScaleCheck.swift) with
the self-test proxy started for it, its `SCALE` lines turned into a report.

    python3 scripts/scale_check.py --app build/unsandboxed/PrivacyBrowser.app --out build/scale \\
        [--profiles 200] [--running 1,5,10,20] [--quit 10] [--title "Scale"]

Writes `scale.json` (every measurement) and `scale.md` (the report) into --out, with the Profiles
window drawn with every profile (`profiles-<N>.png`), and prints the main figures as notices. A
measurement: exit 0 when every step ran (whatever the figures), 1 when one could not.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = "Contents/MacOS/PrivacyBrowser"
PROXY_PORT = 18200


def notice(kind, title, text):
    print(f"::{kind} title={title}::{text[:1500]}", flush=True)


def wait_for_port(port, seconds=20):
    deadline = time.time() + seconds
    while time.time() < deadline:
        with socket.socket() as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.5)
    return False


def report(steps):
    lines = []
    machine = steps.get("machine", [{}])[0]
    lines.append(f"Machine: macOS {machine.get('macOS', '?')}, Safari {machine.get('safari', '?')}, "
                 f"{machine.get('processors', '?')} processors, {round(machine.get('memoryMB', 0) / 1024, 1)} GB of memory.\n")
    create = steps.get("create", [{}])[0]
    if create:
        lines.append(f"**Creating {create['profiles']} profiles:** {round(create['totalMs'] / 1000, 1)} s in all, "
                     f"median {create['medianMs']} ms, slowest {create['maxMs']} ms (first ten {create['firstTenMs']}, "
                     f"last ten {create['lastTenMs']} ms). The vault then takes {round(create['vaultBytes'] / 1048576, 2)} MB, "
                     f"{round(create['bytesPerProfile'] / 1024, 1)} KB per profile.\n")
    listing = steps.get("list", [{}])[0]
    if listing:
        lines.append(f"**The list:** reading the index and decrypting every profile's settings, as the Profiles window does "
                     f"on each refresh: median {listing['refreshMedianMs']} ms for {listing['rows']} rows ({listing['refreshMs']}).\n")
    for search in steps.get("search", [{}])[0].get("queries", []):
        lines.append(f"- search '{search['query']}': {search['found']} found, {search['expected']} expected "
                     f"({'right' if search['right'] else 'WRONG'}), {round(search['ms'], 3)} ms")
    filters = steps.get("filter", [{}])[0]
    for item in filters.get("filters", []):
        lines.append(f"- filter {item['filter']}: {item['found']} found, {item['expected']} expected "
                     f"({'right' if item['right'] else 'WRONG'}), {round(item['ms'], 3)} ms")
    if filters:
        lines.append(f"- tags in the sidebar: {filters['tags']} ({filters['tagsExpected']} expected)\n")
    draw = steps.get("draw", [{}])[0]
    if draw:
        lines.append(f"**The window with {draw['rows']} rows** drawn in {round(draw['ms'] / 1000, 2)} s "
                     f"({'written' if draw['written'] else 'NOT written'}).\n")
    lines.append("**Running at once** (launched as the list's Launch does for a selection; memory: each profile's own "
                 "process and WebKit's that work for it):\n")
    lines.append("| Profiles | Windows up | Start, median / slowest | All up after | Memory, all / per profile | "
                 "Processors busy | Free / compressed / swap | Stop all |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for run in steps.get("run", []):
        machine_memory = run.get("machine", {})
        lines.append(f"| {run['profiles']} | {run['windowsUp']} | {round(run['startMedianMs'] / 1000, 1)} s / "
                     f"{round(run['startMaxMs'] / 1000, 1)} s | {round(run['allWindowsUpMs'] / 1000, 1)} s | "
                     f"{round(run['memoryMB'])} MB / {round(run['memoryPerProfileMB'])} MB | {run['cpuBusyPercent']} % | "
                     f"{round(machine_memory.get('freeMB', -1))} / {round(machine_memory.get('compressedMB', -1))} / "
                     f"{round(machine_memory.get('swapUsedMB', -1))} MB | {round(run['stopAllMs'] / 1000, 1)} s |")
    lines.append("")
    quit_step = steps.get("quit", [{}])[0]
    if quit_step:
        lines.append(f"**Quitting with {quit_step['profiles']} running** ({quit_step['runningAtQuit']} windows up): "
                     f"{round(quit_step['quitMs'] / 1000, 1)} s until every one was sealed; {quit_step['sealsReported']} seals "
                     f"reported, median {quit_step['sealMedianS']} s, slowest {quit_step['sealMaxS']} s, "
                     f"{quit_step['forced']} forced.")
    kept = steps.get("kept", [{}])[0]
    if kept:
        lines.append(f"**Nothing lost:** {kept['cookieKept']} of {kept['profiles']} profiles had their page's cookie after "
                     f"the quit and a new launch. {('Missing: ' + '; '.join(kept['missing'])) if kept['missing'] else ''}")
    last = steps.get("launch-last", [{}])[0]
    if last:
        lines.append(f"**With {last['profiles']} profiles in the vault**, one more launch: "
                     f"{'up' if last['up'] else 'NOT up'} in {round(last['ms'] / 1000, 1)} s.")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--profiles", default="200")
    parser.add_argument("--running", default="1,5,10,20")
    parser.add_argument("--quit", default="10")
    parser.add_argument("--title", default="Scale")
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    proxy = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "selftest_proxy.py"),
                              "--http", str(PROXY_PORT), "--socks", str(PROXY_PORT + 1)],
                             stdout=open(os.path.join(out, "proxy.txt"), "w"), stderr=subprocess.STDOUT)
    if not wait_for_port(PROXY_PORT):
        notice("error", args.title, "the self-test proxy did not start")
        proxy.kill()
        return 1
    environment = dict(os.environ, PB_SELFTEST_HTTP_PROXY_PORT=str(PROXY_PORT), PRIVACYBROWSER_LANG="en")
    with open(os.path.join(out, "scale.txt"), "w") as log:
        try:
            result = subprocess.run([os.path.join(args.app, BINARY), "--scale-check", "--profiles", args.profiles,
                                     "--running", args.running, "--quit", args.quit, "--out", out],
                                    env=environment, stdout=subprocess.PIPE, stderr=log, text=True, timeout=3500)
            output = result.stdout
        except subprocess.TimeoutExpired as expired:
            output = expired.stdout.decode(errors="replace") if isinstance(expired.stdout, bytes) else (expired.stdout or "")
        log.write(output)
    proxy.kill()
    steps = {}
    for line in output.splitlines():
        if line.startswith("SCALE "):
            try:
                entry = json.loads(line[len("SCALE "):])
            except ValueError:
                continue
            steps.setdefault(entry.get("step", "?"), []).append(entry)
        elif line.startswith(("SCALE-ERROR", "SCALE-DONE")):
            print(line, flush=True)
    with open(os.path.join(out, "scale.json"), "w") as handle:
        json.dump(steps, handle, indent=1, ensure_ascii=False)
    text = report(steps)
    with open(os.path.join(out, "scale.md"), "w") as handle:
        handle.write(text)
    print(text, flush=True)
    for line in text.splitlines():
        if line.startswith(("**", "| ")) and not line.startswith("|---"):
            notice("notice", args.title, line.replace("**", ""))
    return 0 if "SCALE-DONE" in output else 1


if __name__ == "__main__":
    sys.exit(main())
