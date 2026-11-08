#!/usr/bin/env python3
"""Measurement (never merged): the window settings (bwsp) a .DS_Store holds, every key."""
import plistlib, sys
d = open(sys.argv[1], "rb").read()
i = 0
while (i := d.find(b"bplist00", i)) >= 0:
    for end in range(i + 40, min(len(d), i + 4000)):
        try:
            p = plistlib.loads(d[i:end])
        except Exception:
            continue
        if isinstance(p, dict) and "WindowBounds" in p:
            print("bwsp:", p)
        break
    i += 8
