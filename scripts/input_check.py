#!/usr/bin/env python3
"""What a click brings a page in a mobile view and in a Mac profile, and where a profile's process
stops when it stops answering (a measurement on claude/measure-touch, never merged).

    python3 scripts/input_check.py --app build/unsandboxed/Lumen.app --out build/input [--sites a,b] [--mobile ios-27]

Runs `Lumen --input-check` (InputCheck.swift) and prints its INPUT lines as they come. On an
INPUT-STALL line — a profile's main thread silent for 10 s, or a page that did not answer after a
click — the main threads of the profile's process, of every WebKit WebContent process and of the
app are written down with the tool of the menu walk (scripts/menu_walk.py's main_thread: spindump
as root, else sample; run 672), as INPUT-STACK lines, the whole reports kept in --out. Then a
report: for each profile and site, what the page is told (touch, pointer), what it listens to, and
for each element clicked, the events that came in order and whether the page did anything.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import menu_walk  # noqa: E402  (its main_thread and processes: the stacks of run 672)

BINARY = "Contents/MacOS/Lumen"


def stacks(stall, app_pid, out):
    """The main threads of the stalled profile's process, of WebKit's content processes, of the app."""
    targets = []
    if isinstance(stall.get("pid"), int) and stall["pid"] > 0:
        targets.append((stall["pid"], f"profile-{stall.get('profile')}"))
    for pid, _parent, executable in menu_walk.processes():
        name = os.path.basename(executable)
        if "com.apple.WebKit.WebContent" in name or "com.apple.WebKit.Networking" in name or name.startswith("com.apple.WebKit.GPU"):
            targets.append((pid, name.replace("com.apple.WebKit.", "webkit-")))
    targets.append((app_pid, "app"))
    for pid, name in targets:
        for line in menu_walk.main_thread(pid, out, f"{stall.get('n')}-{name}"):
            print(f"INPUT-STACK {stall.get('n')} {name} {pid}: {line}", flush=True)


def compress(events):
    """click's events in order, as `type(pointerType)` with repeats folded: the sequence a page saw."""
    said = []
    for event in events or []:
        word = event.get("type", "?")
        if event.get("pointerType"):
            word += f"({event['pointerType']})"
        if event.get("prevented"):
            word += "!prevented"
        if not event.get("trusted", True):
            word += "[untrusted]"
        if said and said[-1].split("×")[0] == word:
            count = int(said[-1].split("×")[1]) + 1 if "×" in said[-1] else 2
            said[-1] = f"{word}×{count}"
        else:
            said.append(word)
    return " ".join(said) or "nothing"


def report(lines):
    print("\n==== What a click brought the page ====", flush=True)
    for entry in lines:
        step = entry.get("step")
        who = f"[{entry.get('profile', '?')}] {entry.get('site', '')}"
        if step == "page":
            env = entry.get("environment") or {}
            touch = {k: env.get(k) for k in ("maxTouchPoints", "ontouchstart", "TouchEvent", "pointerCoarse", "hoverNone")}
            counts = entry.get("listenerCounts") or {}
            print(f"\n{who}: {entry.get('href')} «{entry.get('title')}», loaded in {entry.get('loadMs')} ms", flush=True)
            print(f"  told: {json.dumps(touch)}; UA {'iPhone' if 'iPhone' in env.get('userAgent', '') else 'Mac'}; "
                  f"viewport {env.get('innerWidth')}×{env.get('innerHeight')}")
            print(f"  listeners added: {json.dumps(counts, sort_keys=True)}; on window/document/html/body: "
                  f"{json.dumps(entry.get('listenersOnRoots') or {}, sort_keys=True)}")
            print(f"  elements with their own: {entry.get('elementsWithListeners')}; groups: {json.dumps(entry.get('groupsFound'))}")
            if entry.get("error"):
                print(f"  ERROR {entry['error']}")
        elif step == "click":
            if entry.get("error"):
                print(f"  click {entry.get('index')}: {entry['error']} ({json.dumps(entry.get('target'))})")
                continue
            target = entry.get("target") or {}
            did = []
            if entry.get("mutations"):
                did.append(f"{entry['mutations']} DOM changes")
            if entry.get("urlBefore") != entry.get("urlAfter"):
                did.append(f"went to {entry.get('urlAfter')}")
            if entry.get("sameDocumentHrefChanged"):
                did.append("its address changed")
            if entry.get("fired"):
                did.append("fired " + ",".join(entry["fired"]))
            if not entry.get("pageAnswered"):
                did.append("THE PAGE DID NOT ANSWER after it")
            print(f"  click {entry.get('index')} [{target.get('group')}] {target.get('element')} «{target.get('text')}»")
            print(f"     events: {compress(entry.get('events'))}")
            print(f"     page did: {'; '.join(did) or 'nothing seen'}")
        elif step == "after-click":
            print(f"     then: {entry.get('url')} readyState {entry.get('readyState')} in {entry.get('ms')} ms"
                  f"{'' if entry.get('answeredFirstTry') else ' (did not answer at first)'}")
        elif step in ("stall", "frozen", "thawed", "process-ended", "probe-timeout", "launch-error"):
            print(f"  {step.upper()}: {json.dumps(entry, sort_keys=True)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--sites")
    parser.add_argument("--mobile")
    parser.add_argument("--profiles")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    command = [os.path.join(args.app, BINARY), "--input-check", "--out", os.path.abspath(args.out)]
    for name in ("sites", "mobile", "profiles"):
        if getattr(args, name):
            command += [f"--{name}", getattr(args, name)]
    log = open(os.path.join(args.out, "app.log"), "w")
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=log, text=True, errors="replace")
    entries, stalls = [], []

    def read():
        for raw in process.stdout:
            line = raw.rstrip("\n")
            if not line.startswith("INPUT"):
                continue
            print(line, flush=True)
            kind, _, body = line.partition(" ")
            try:
                fields = json.loads(body) if body.startswith("{") else {}
            except ValueError:
                fields = {"step": "unreadable", "line": line[:300]}
            if kind == "INPUT":
                entries.append(fields)
            elif kind == "INPUT-STALL":
                stalls.append(fields)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    handled = 0
    started = time.time()
    while process.poll() is None or handled < len(stalls):
        while handled < len(stalls):
            stall = stalls[handled]
            handled += 1
            stacks(stall, process.pid, args.out)
            open(os.path.join(args.out, f"stacks-{stall.get('n')}"), "w").close()
        if time.time() - started > 55 * 60:
            print("INPUT-ERROR the check did not finish in 55 minutes; the app's main thread:", flush=True)
            for line in menu_walk.main_thread(process.pid, args.out, "app-deadline"):
                print(f"INPUT-STACK app {process.pid}: {line}", flush=True)
            process.kill()
            break
        time.sleep(0.5)
    reader.join(timeout=10)
    report(entries)
    print(f"\ninput check: exit {process.returncode}, {len(stalls)} stall(s)")
    return 0 if process.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
