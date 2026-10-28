#!/usr/bin/env python3
"""Prints why a process crashed, from a macOS crash report (.ips): the exception, the termination
reason, the application-specific information (an assertion's or abort's message), the last Objective-C
exception's backtrace, and the top frames of the thread that crashed.

    python3 -I scripts/safari_graph/crash_summary.py REPORT.ips [REPORT.ips …]

Used by measure.sh after each attempt to run Safari's interface in the probe (SAFARI_GRAPH spike).
An .ips file is two JSON documents: a one-line header, then the report.
"""
import json
import sys


def load(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    first, _, rest = text.partition("\n")
    try:
        header = json.loads(first)
    except ValueError:
        header = {}
    try:
        body = json.loads(rest) if rest.strip() else {}
    except ValueError:
        body = {}
    return header, body


def frames(body, frame_list, limit):
    images = body.get("usedImages", [])
    out = []
    for frame in frame_list[:limit]:
        index = frame.get("imageIndex")
        image = images[index].get("name", "?") if isinstance(index, int) and 0 <= index < len(images) else "?"
        symbol = frame.get("symbol") or hex(frame.get("imageOffset", 0))
        out.append(f"    {image}  {symbol}")
    return out


def summarize(path):
    header, body = load(path)
    lines = [f"== crash report {path}",
             f"  process: {body.get('procName') or header.get('name')} ({body.get('procPath', '?')})"]
    exception = body.get("exception") or {}
    if exception:
        lines.append(f"  exception: {exception.get('type')} {exception.get('signal', '')} {exception.get('codes', '')}".rstrip())
    termination = body.get("termination") or {}
    if termination:
        lines.append(f"  termination: {termination.get('namespace')} {termination.get('indicator', '')} "
                     f"{' '.join(termination.get('reasons', []) or [])}".rstrip())
    for image, messages in (body.get("asi") or {}).items():
        for message in messages:
            lines.append(f"  application-specific ({image}): {message}")
    last = body.get("lastExceptionBacktrace") or []
    if last:
        lines.append("  last Objective-C exception backtrace:")
        lines += frames(body, last, 12)
    for thread in body.get("threads", []):
        if thread.get("triggered"):
            lines.append(f"  crashed thread {thread.get('id', '?')} {thread.get('queue', '')}".rstrip() + ":")
            lines += frames(body, thread.get("frames", []), 18)
    return "\n".join(lines)


def main(paths):
    for path in paths:
        try:
            print(summarize(path))
        except OSError as error:
            print(f"== crash report {path}: unreadable ({error})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
