#!/usr/bin/env python3
"""Fails when the app logs something private to the unified log in clear.

The vault keeps profile names, proxy hosts, exit IPs, URLs and the user's settings encrypted at
rest; a log line written with `privacy: .public` keeps whatever it interpolates in plaintext in
/var/db/diagnostics (notice level and above), readable with `log show` and shipped in a
sysdiagnose. So an interpolation marked public must be one of the things below, which say nothing
about the user or their browsing: a profile's random UUID, a count or size, a process id, a status
or enum raw value, a yes/no, or the name of a class, method or hook this build looks for.

Anything else is private (`privacy: .private`, the default for strings). An expression that is
safe but not recognised here is listed in ALLOWED_EXPRESSIONS with the reason it is safe.

Usage: scripts/check_log_privacy.py [source root]   (default: Sources)
"""
import os
import re
import sys

# What a public interpolation may end with, or be.
SAFE_PATTERNS = [
    r"\.uuidString$",                    # a profile's random id
    r"(\.|^)count$", r"\.files$", r"\.bytes$",
    r"processIdentifier$",
    r"\.rawValue$",
    r"(==|!=) nil$",                     # a yes/no
    r"^(true|false)$",
    r"\.logKind\b",                      # an error's type, domain and code, not its text
    r"^Int\(",                            # a number
    r"NSStringFromClass\(", r"type\(of:",  # a class name
]

# Safe expressions the patterns do not recognise, each with why.
ALLOWED_EXPRESSIONS = {
    # Numbers and yes/no values.
    "carried": "how many proxy configurations a store carries",
    "restored": "a count of restored items",
    "sitesAdded": "a count",
    "self.cookiesCollected": "a count",
    "installed": "a yes/no or a count of hooks",
    "bundled": "a yes/no: whether a bundled file was used",
    "absent": "names of private classes and methods this macOS does not have",
    "onProfile": "a yes/no",
    "status": "a process exit status",
    "missing": "names of private classes and methods this macOS does not have",
    "missing ? \"requested, no credentials set\" : \"rejected\"": "a fixed text",
    "configuration.lastProxyLocation == nil ? \"the system time zone\" : \"the last known location\"": "a fixed text",
    # Names of this build's own hooks, classes and methods, from the code, not from the user.
    "className": "an Objective-C class name from this build's list",
    "selectorName": "a selector from this build's list",
    "hook": "the name of one of this build's hooks",
    "frame": "a frame of a call stack: symbol names of system frameworks",
    "scheme": "a URL scheme (http, https, file…), not the address",
    "wanted": "a yes/no: whether the profile has a proxy",
    "exceptionName": "an Objective-C exception's name (its reason is logged privately)",
    "origin": "which initializer built a web view, a label in the code",
    "closures.sorted.joined(separator: \", \")": "which kernel closures applied, labels in the code",
    "enabled ? schedule.everyHours : 0": "a number of hours",
    "(message.body as? [String: Any])?[\"type\"] as? String ?? \"?\"":
        "the kind of message AutoFill's own script sent, from its content world, which pages cannot post to",
}

# Safe in one file only, where the name means something harmless.
ALLOWED_IN_FILE = {
    ("SafariChrome.swift", "path"): "a Safari framework's path, under /System or /Applications",
    ("SafariChrome.swift", "reason"): "dlerror() for a Safari framework",
    ("SafariChrome.swift", "name"): "a nib's name in Safari's frameworks",
    ("SafariChrome.swift", "url.path"): "a nib inside Safari's frameworks",
    ("SafariChrome.swift", "bundle?.bundlePath ?? \"the main bundle\""): "a bundle's path",
    ("SafariChrome.swift", "String(cString: strerror(errno))"): "a system error's text",
    ("SafariChrome.swift", "String(describing: NSApp.map { type(of: $0) })"): "a class name",
    ("SafariChromeHost.swift", "structural.joined(separator: \", \")"): "names of Safari's classes this macOS lacks",
    ("SafariChromeHost.swift", "patched.joined(separator: \", \")"): "names of Safari's configuration factories",
    ("ProxyGeoLookup.swift", "service.url.host ?? \"?\""): "a geolocation service of the app's own list, not the proxy",
}

def interpolations(text):
    """Yields (offset, inner) for every \\( ... ) in text, nested parentheses included."""
    i = 0
    while True:
        i = text.find("\\(", i)
        if i < 0:
            return
        depth, j = 1, i + 2
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        yield i, text[i + 2:j - 1]
        i = j

def split_privacy(inner):
    """The interpolated expression and its privacy argument, if any (top-level comma only)."""
    depth = 0
    for k, ch in enumerate(inner):
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            rest = inner[k + 1:].strip()
            if rest.startswith("privacy:"):
                return inner[:k].strip(), rest
    return inner.strip(), None

def is_safe(expression, path):
    if expression in ALLOWED_EXPRESSIONS or (os.path.basename(path), expression) in ALLOWED_IN_FILE:
        return True
    return any(re.search(pattern, expression) for pattern in SAFE_PATTERNS)

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "Sources"
    problems = []
    for folder, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            text = open(path, encoding="utf-8").read()
            for offset, inner in interpolations(text):
                expression, privacy = split_privacy(inner)
                if privacy is None or not privacy.startswith("privacy: .public"):
                    continue
                if not is_safe(expression, path):
                    line = text.count("\n", 0, offset) + 1
                    problems.append(f"{path}:{line}: `{expression}` is logged with privacy: .public")
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} interpolation(s) would keep something of the user's in the system log in clear: "
              "make them privacy: .private, or add them to ALLOWED_EXPRESSIONS with why they are safe.")
        return 1
    print("log privacy: every public interpolation is an id, a count, a status or a name from the code")
    return 0

if __name__ == "__main__":
    sys.exit(main())
