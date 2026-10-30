#!/usr/bin/env python3
"""What crashed, in a few lines: the summary of macOS crash reports (.ips) of this app's processes
and of WebKit's.

    python3 scripts/crash_summary.py ~/Library/Logs/DiagnosticReports/PrivacyBrowser*.ips ...

A profile's own process that dies leaves the self-test only "the profile quit unexpectedly"; the
system writes what happened to a crash report. For each report given this prints the process,
when, the exception and signal, the termination reason, any message the process left (an abort's,
a Swift runtime error's), and the crashed thread's frames, image and symbol — enough to find the
line, without the whole report. Exit 0 always: a summary, not a verdict.
"""

import json
import sys

FRAMES = 40


def summarize(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    header_text, _, body_text = text.partition("\n")
    try:
        header = json.loads(header_text)
        body = json.loads(body_text)
    except ValueError:
        print(f"CRASH {path}: not a JSON crash report; its first lines:")
        print("\n".join(text.splitlines()[:30]))
        return
    process = body.get("procName") or header.get("app_name") or "?"
    print(f"CRASH {process} (pid {body.get('pid', '?')}) at {header.get('timestamp', body.get('captureTime', '?'))}: {path}")
    exception = body.get("exception") or {}
    print(f"CRASH   exception {exception.get('type', '?')} signal {exception.get('signal', '?')} "
          f"codes {exception.get('codes', '?')} subtype {exception.get('subtype', '')}".rstrip())
    termination = body.get("termination") or {}
    if termination:
        print(f"CRASH   termination {termination.get('namespace', '?')} {termination.get('indicator', '')} "
              f"{' | '.join(termination.get('reasons', []) or [])}".rstrip())
    for key in ("asi", "vmRegionInfo", "ktriageinfo"):
        if body.get(key):
            print(f"CRASH   {key}: {json.dumps(body[key], ensure_ascii=False)[:1500]}")
    images = body.get("usedImages") or []
    threads = body.get("threads") or []
    faulting = body.get("faultingThread")
    crashed = next((t for t in threads if t.get("triggered")), None)
    if crashed is None and isinstance(faulting, int) and 0 <= faulting < len(threads):
        crashed = threads[faulting]
    backtraces = [("crashed thread", crashed)] if crashed else []
    if body.get("lastExceptionBacktrace"):
        backtraces.append(("last exception", {"frames": body["lastExceptionBacktrace"]}))
    for title, thread in backtraces:
        name = thread.get("name") or thread.get("queue") or ""
        print(f"CRASH   {title} {name}".rstrip() + ":")
        for index, frame in enumerate((thread.get("frames") or [])[:FRAMES]):
            image_index = frame.get("imageIndex")
            image = images[image_index].get("name", "?") if isinstance(image_index, int) and image_index < len(images) else "?"
            symbol = frame.get("symbol") or f"+{frame.get('imageOffset', '?')}"
            location = frame.get("symbolLocation")
            source = f" ({frame['sourceFile']}:{frame.get('sourceLine', '?')})" if frame.get("sourceFile") else ""
            print(f"CRASH     {index:2d} {image:<32} {symbol}{f' + {location}' if location is not None else ''}{source}")


def main():
    paths = sys.argv[1:]
    if not paths:
        print("CRASH none: no crash report of the app's or WebKit's processes")
        return 0
    for path in paths:
        try:
            summarize(path)
        except OSError as error:
            print(f"CRASH {path}: unreadable ({error})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
