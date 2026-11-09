#!/usr/bin/env python3
"""The owner's rules for the App Store build (8 November, second version), checked in the sources and
in the built app.

1. Positioning: the app is a browser of isolated sessions for testing — "сессии", "изоляция",
   "профиль устройства", "тестирование". None of the words below may appear in what the person reads,
   in a screen's name or in Info.plist: they decide whether the app reaches people at all.
2. No App-Bound Domains: WKAppBoundDomains is not declared and limitsNavigationsToAppBoundDomains is
   never turned on — the device profile works on every site, at the price of service workers
   (LIMITATIONS.md).
3. The account (9 November): the app trusts documents of rights signed by the owner's key(s) only.
   Neither the development server's key nor the testbed's — keys anyone knows — may be in the app's
   sources, in project.yml or in the built Info.plist: with one, anyone could sign themselves a plan.

    python3 ios/scripts/release_rules.py [ios-dir] [--app Lumen.app]   -> exit 0, or 1 listing each breach

What is scanned: every string literal of the app's Swift sources (ios/Lumen, without Debug/, which a
release build does not contain) — texts, screen names, accessibility labels and identifiers alike —,
the Info.plist values in project.yml, any .strings file, the product description's section of
LIMITATIONS.md, and with --app every string of the built Info.plist. ios/scripts/test_release_rules.py plants each word, and each App-Bound breach (the reds).
"""
import os
import plistlib
import re
import sys

# The owner's list, then the forms around it (any ending, with or without a hyphen), then English.
WORDS = {
    "антидетект": r"анти-?\s?детект",
    "обход": r"\bобход",
    "фингерпринт": r"фингерпринт",
    "подмена отпечатка": r"\bподмен\w*\s+отпечат",
    "мультиаккаунт": r"мульти-?\s?аккаунт",
    # Wider than the list, in its spirit: "отпечаток" and "подмена" alone say the same.
    "отпечаток": r"\bотпечат",
    "подмена": r"\bподмен",
    "antidetect": r"anti-?\s?detect",
    "fingerprint": r"finger-?\s?print",
    "spoof": r"spoof",
    "bypass": r"\bby-?pass",
    "multi-account": r"multi-?\s?account",
}
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
# Keys anyone knows: the development server's (the server's CONTRACT.md §7.2) and the testbed's
# stand-in's (ios/testbed/account.py --key) — each by its id and by the key itself.
KNOWN_KEYS = {
    "the development server's key": ("445c6300da0205b1", "/+/sbiH55nmy+2gRqQz12E0spl9L/YDWvjnecaN2M1c="),
    "the testbed's key": ("cbbc653cdb8bd787", "dNOl9JtGQJg6VOEIn3+1dscg5hWYkx9XUqm+qJ5CnZc="),
}


def known_key_in(text):
    for name, parts in KNOWN_KEYS.items():
        if any(part in text for part in parts):
            return name
    return None


def word_in(text):
    for name, pattern in WORDS.items():
        if re.search(pattern, text, re.IGNORECASE):
            return name
    return None


def swift_files(ios):
    for folder, dirs, files in os.walk(os.path.join(ios, "Lumen")):
        dirs[:] = [d for d in dirs if d != "Debug"]   # DEBUG-only screens: not in a release build
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(folder, name)


def plist_strings(value, path=""):
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from plist_strings(item, f"{path}.{key}" if path else key)
    elif isinstance(value, list):
        for i, item in enumerate(value):
            yield from plist_strings(item, f"{path}[{i}]")


def scan(ios, app=None):
    """Every breach as (where, rule, text)."""
    found = []

    def judge(where, text):
        word = word_in(text)
        if word:
            found.append((where, f"word «{word}»", text))

    for path in swift_files(ios):
        rel = os.path.relpath(path, ios)
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            for text in LITERAL.findall(line):
                judge(f"{rel}:{number}", text)
            if known_key_in(line):
                found.append((f"{rel}:{number}", "known-key", f"{known_key_in(line)}: {line.strip()}"))
            code = LITERAL.sub('""', line).split("//", 1)[0]   # the code itself: no literals, no comment
            if "limitsNavigationsToAppBoundDomains" in code and not re.search(r"limitsNavigationsToAppBoundDomains\s*=\s*false", code):
                found.append((f"{rel}:{number}", "app-bound", line.strip()))
    for folder, _, files in os.walk(os.path.join(ios, "Lumen")):
        for name in files:
            if name.endswith(".strings"):
                path = os.path.join(folder, name)
                for number, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                    for text in LITERAL.findall(line):
                        judge(f"{os.path.relpath(path, ios)}:{number}", text)
    project = os.path.join(ios, "project.yml")
    if os.path.exists(project):
        lines = open(project, encoding="utf-8").read().splitlines()
        if any("WKAppBoundDomains" in line for line in lines):
            found.append(("project.yml", "app-bound", "WKAppBoundDomains is declared"))
        # Info.plist values (NS…Description, CFBundleDisplayName…): any "Key: value" line of the file.
        for number, line in enumerate(lines, 1):
            if known_key_in(line):
                found.append((f"project.yml:{number}", "known-key", f"{known_key_in(line)}: {line.strip()}"))
            m = re.match(r"\s*(NS\w+|CF\w+|UI\w+|LS\w+):\s*(.+)$", line)
            if m:
                judge(f"project.yml:{number}", m.group(2).strip().strip("\"'"))
    # The product description's text (LIMITATIONS.md, its first section) goes to the store and the site.
    limits = os.path.join(ios, "LIMITATIONS.md")
    if os.path.exists(limits):
        section = False
        for number, line in enumerate(open(limits, encoding="utf-8"), 1):
            if line.startswith("## "):
                section = line.strip() == "## Для описания продукта"
            elif section:
                judge(f"LIMITATIONS.md:{number}", line.strip())
    if app:
        with open(os.path.join(app, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
        if "WKAppBoundDomains" in info:
            found.append((os.path.basename(app) + "/Info.plist", "app-bound", f"WKAppBoundDomains = {info['WKAppBoundDomains']!r}"))
        for key, value in plist_strings(info):
            judge(f"{os.path.basename(app)}/Info.plist {key}", value)
            if known_key_in(key + " " + value):
                found.append((f"{os.path.basename(app)}/Info.plist {key}", "known-key", known_key_in(key + " " + value)))
    return found


def main(argv):
    args = argv[1:]
    app = None
    if "--app" in args:
        i = args.index("--app")
        app = args[i + 1]
        del args[i:i + 2]
    ios = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    found = scan(ios, app)
    if found:
        print("RELEASE RULES BROKEN:", file=sys.stderr)
        for where, rule, text in found:
            print(f"  [{rule}] {where}: {text}", file=sys.stderr)
        return 1
    print("release rules: none of the positioning words, no App-Bound Domains, no key anyone knows"
          + (f" (and {os.path.basename(app)})" if app else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
