#!/usr/bin/env python3
"""Nothing in the app asks the system to open something except through `SystemOpen`.

    python3 scripts/check_system_opens.py [source root]     (default: Sources)
    python3 scripts/check_system_opens.py --self-check       (the check against planted lines)

What an app hands the system leaves every profile: another app fetches an address as this Mac,
with this Mac's own address, cookies and accounts. "What sites see" opened its page in this Mac's
Safari by itself until 1 November (the owner's finding). `SystemOpen` (Sources/PrivacyBrowser/App/
SystemOpen.swift) is the one place that may: each kind of opening is named there with why it is
allowed, and a profile's own process is refused all of them. This fails on any other call of
NSWorkspace's opening methods, SMAppService's settings, SwiftUI's `Link` or `openURL` action, or
LaunchServices' open calls — outside the files listed in ALLOWED with the reason each is allowed.

`--self-check` runs the same scan over planted lines — each forbidden form in a file of its own,
and the allowed forms — and fails unless every forbidden one is found and no allowed one is: a scan
that cannot fail checks nothing.
"""
import os
import re
import sys
import tempfile

FORBIDDEN = [
    (re.compile(r"NSWorkspace\.shared\.(open|openApplication|activateFileViewerSelecting|selectFile|openFile)\s*\("),
     "NSWorkspace opening"),
    (re.compile(r"\bopenSystemSettingsLoginItems\s*\("), "SMAppService's System Settings"),
    (re.compile(r"(^|[^\w.])Link\s*\("), "SwiftUI Link"),
    (re.compile(r"@Environment\(\\\.openURL\)|\.environment\(\\\.openURL"), "SwiftUI's openURL action"),
    (re.compile(r"\bLSOpen\w*\s*\("), "LaunchServices open"),
    (re.compile(r"\bNSApp\.open\w*\s*\(|NSApplication\.shared\.open\w*\s*\("), "NSApplication opening"),
]

# The one place, and the files that may call the system directly, each with why.
ALLOWED = {
    os.path.join("PrivacyBrowser", "App", "SystemOpen.swift"):
        "the one place itself",
    os.path.join("PrivacyBrowser", "Browser", "ProfileNetworkGuard.swift"):
        "the network report's hand-off probe: in a profile's process it asks NSWorkspace to open an "
        "address and must be refused by HandOffs (the self-test fails if it is not)",
    os.path.join("PrivacyBrowserUpdater", "main.swift"):
        "the update installer, a separate executable, starting the updated app again",
}


def scan(root):
    """(path, line number, what, line) for every forbidden call outside ALLOWED."""
    found = []
    for directory, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            if relative in ALLOWED:
                continue
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, 1):
                    code = line.split("//", 1)[0]
                    for pattern, what in FORBIDDEN:
                        if pattern.search(code):
                            found.append((relative, number, what, line.strip()))
    return found


def self_check():
    forbidden = {
        "a.swift": 'NSWorkspace.shared.open(url)',
        "b.swift": 'try await NSWorkspace.shared.openApplication(at: helper, configuration: c)',
        "c.swift": 'NSWorkspace.shared.activateFileViewerSelecting([root])',
        "d.swift": 'SMAppService.openSystemSettingsLoginItems()',
        "e.swift": '        Link("Website", destination: url)',
        "f.swift": '@Environment(\\.openURL) private var openURL',
        "g.swift": 'LSOpenCFURLRef(url as CFURL, nil)',
        "h.swift": 'NSApp.open(url)',
    }
    allowed = {
        "i.swift": 'SystemOpen.openWebsite(link.url)',
        "j.swift": '// NSWorkspace.shared.open(url) said in a comment only',
        "k.swift": 'struct WebLink: Identifiable { let name: String }',
        "l.swift": 'let reveal = SystemOpen.revealInFinder([root])',
    }
    with tempfile.TemporaryDirectory() as root:
        for name, line in {**forbidden, **allowed}.items():
            with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
                handle.write(line + "\n")
        flagged = {path for path, *_ in scan(root)}
    missed = sorted(set(forbidden) - flagged)
    wrong = sorted(flagged & set(allowed))
    if missed or wrong:
        print(f"system opens self-check FAILED: forbidden not found {missed}, allowed flagged {wrong}")
        return 1
    print(f"system opens self-check: {len(forbidden)} forbidden forms found, {len(allowed)} allowed ones not")
    return 0


def main():
    if "--self-check" in sys.argv[1:]:
        return self_check()
    root = next((argument for argument in sys.argv[1:] if not argument.startswith("--")), "Sources")
    found = scan(root)
    for path, number, what, line in found:
        print(f"{path}:{number}: {what} outside SystemOpen: {line}")
    if found:
        print(f"\n{len(found)} call(s) hand something to the system outside SystemOpen: go through it "
              "(Sources/PrivacyBrowser/App/SystemOpen.swift), or list the file in ALLOWED with why.")
        return 1
    print(f"system opens: only through SystemOpen ({len(ALLOWED) - 1} file(s) allowed besides it, each with why)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
