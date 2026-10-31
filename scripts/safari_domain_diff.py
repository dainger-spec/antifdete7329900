#!/usr/bin/env python3
"""A measurement (never merged): the real Safari's com.apple.Safari domain, as `defaults export`
reads it (cfprefsd, Safari's container), compared before and after: safari_domain_diff.py BEFORE AFTER"""
import plistlib
import sys

before = plistlib.load(open(sys.argv[1], "rb"))
after = plistlib.load(open(sys.argv[2], "rb"))
added = sorted(set(after) - set(before))
removed = sorted(set(before) - set(after))
changed = sorted(key for key in set(before) & set(after) if before[key] != after[key])
print(f"SAFARI-DOMAIN {len(before)} keys before, {len(after)} after: added {len(added)}, removed {len(removed)}, changed {len(changed)}")
for key in added:
    print(f"SAFARI-DOMAIN added {key} = {str(after[key])[:160]}")
for key in removed:
    print(f"SAFARI-DOMAIN removed {key} (was {str(before[key])[:160]})")
for key in changed:
    print(f"SAFARI-DOMAIN changed {key}: {str(before[key])[:120]} -> {str(after[key])[:120]}")
