#!/usr/bin/env python3
"""The content rules of a session with a proxy (Lumen/Resources/proxied-rules.json), read as WebKit
reads them: a load is blocked when a rule's url-filter matches its URL, its resource type is the rule's
(when the rule names one), and the page's top URL matches none of the rule's unless-top-url. Patterns
are matched case-insensitively against the whole canonical URL, user info and all.

What the list must do: block every ping, and every load to this device's own addresses from a page that
is not itself on this device — and not take a page for one on this device because its address starts
with a user name and password that look like this device (`http://127.0.0.1:1@site.example/`: the
user is "127.0.0.1", the password "1", the host site.example). A pattern that ended its host with
`[:/]` matched "127.0.0.1:" in such an address and let that page reach this device's ports; each now
ends with an optional port and the path's slash, `(:[0-9]+)?/`, which only the host itself is followed
by. The old ending is the red: rebuilt from the shipped list, it must let the page through.

    python3 ios/scripts/test_proxied_rules.py [proxied-rules.json]   -> exit 0, or 1 listing each failure
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "Lumen", "Resources", "proxied-rules.json")

failures = 0


def check(what, ok, detail=""):
    global failures
    print(("ok    " if ok else "FAIL  ") + what + (f" — {detail}" if detail and not ok else ""))
    failures += 0 if ok else 1


def matches(pattern, text):
    return re.search(pattern, text, re.IGNORECASE) is not None


def blocks(rules, url, top, resource="fetch"):
    for rule in rules:
        trigger = rule["trigger"]
        if rule["action"]["type"] != "block":
            continue
        if "resource-type" in trigger and resource not in trigger["resource-type"]:
            continue
        if not matches(trigger["url-filter"], url):
            continue
        if any(matches(p, top) for p in trigger.get("unless-top-url", [])):
            continue
        return True
    return False


rules = json.load(open(PATH, encoding="utf-8"))
host_rules = [r for r in rules if "unless-top-url" in r["trigger"]]
patterns = [r["trigger"]["url-filter"] for r in host_rules]

# The list's shape: one rule for pings, one per address of this device, each with every address as
# its exception (the Mac's ProxiedContentRules, from which the list was made).
check("one rule for pings, then one per address of this device", len(rules) == 1 + len(patterns) and len(patterns) == 8,
      f"{len(rules)} rules, {len(patterns)} addresses")
check("each rule's exceptions are the same addresses", all(r["trigger"]["unless-top-url"] == patterns for r in host_rules))
check("each pattern takes a user name and password before the host",
      all(p.startswith("^[a-z]+://([^/?#@]*@)?") for p in patterns))
check("no host ends with [:/] (a password could stand there)", not any(p.endswith("[:/]") for p in patterns),
      repr([p for p in patterns if p.endswith("[:/]")]))
# WebKit's url-filter subset: no alternation, no counted repetition, no shorthand classes.
check("only WebKit's subset of regular expressions", not any(re.search(r"\||\{|\\[dDwWsSb]", p) for p in patterns))

remote = "https://site.example/page"
own = [
    "http://127.0.0.1:631/", "http://127.0.0.1/", "http://127.1.2.3:9/x", "ws://127.0.0.1:8080/socket",
    "http://x@127.0.0.1:631/", "http://user:pass@127.0.0.1/", "http://0.0.0.0:80/", "http://0.0.0.0/",
    "http://localhost/", "http://localhost:3000/", "http://localhost./", "http://localhost.:3000/",
    "http://x@localhost:8080/", "http://printer.localhost/", "http://a.b.localhost:5000/", "http://a.localhost.:1/",
    "http://[::1]/", "http://[::1]:8080/", "http://x@[::1]:8080/", "http://[::]/", "http://[::ffff:7f00:1]/",
    "http://[::ffff:0:0]:80/", "HTTP://LOCALHOST:80/",
]
for url in own:
    check(f"a page from the internet does not reach {url}", blocks(rules, url, remote))
    check(f"a page on this device reaches {url}", not blocks(rules, url, "http://127.0.0.1:8080/"))
for url in ["https://site.example/", "http://127.0.0.1.site.example/", "http://localhost.site.example:8080/",
            "http://127.0.0.1:1@site.example/", "http://localhost:80@site.example/", "http://site.example/127.0.0.1:80/",
            "http://site.example/?u=http://127.0.0.1:631/", "http://notlocalhost/", "http://localhostx:80/"]:
    check(f"an address elsewhere goes on: {url}", not blocks(rules, url, remote))
check("a ping is blocked, even from this device", blocks(rules, "https://site.example/ping", "http://127.0.0.1:8080/", "ping"))

# The page's own address decides the exception: only a page on this device keeps its loads.
local_tops = ["http://127.0.0.1:8080/", "http://127.0.0.1/", "http://x@127.0.0.1:8080/app", "http://0.0.0.0:3000/",
              "http://localhost/", "http://localhost:5173/", "http://localhost.:1/", "http://user:pw@localhost:3000/",
              "http://dev.localhost:8080/", "http://[::1]:8080/", "http://[::ffff:7f00:1]/"]
lookalikes = ["http://127.0.0.1:1@site.example/", "http://127.0.0.1@site.example/", "http://localhost:1@site.example/",
              "http://localhost.:1@site.example/", "http://0.0.0.0:80@site.example/", "http://a.localhost:5@site.example/",
              "http://127.0.0.1:631@site.example:8443/page", "https://127.0.0.1:1@site.example/"]
for top in local_tops:
    check(f"the page {top} is on this device: its loads stay", not blocks(rules, "http://127.0.0.1:631/", top))
for top in lookalikes:
    check(f"the page {top} is not on this device: no load to it", blocks(rules, "http://127.0.0.1:631/", top))
    check(f"  …nor to localhost from it", blocks(rules, "ws://localhost:9222/devtools", top))

# The red: the same list with the old ending takes a lookalike page for one on this device.
old = json.loads(json.dumps(rules).replace("(:[0-9]+)?/", "[:/]"))
check("red — the old ending [:/] lets 127.0.0.1:1@site.example reach this device (the hole, reproduced)",
      not blocks(old, "http://127.0.0.1:631/", "http://127.0.0.1:1@site.example/"))
check("red — the old ending blocked every address the new one blocks",
      all(blocks(old, url, remote) for url in own))

print(f"{failures} failed")
sys.exit(1 if failures else 0)
