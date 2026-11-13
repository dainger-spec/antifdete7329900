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

4. No test switch in a release (the lead, 10 November): a DEBUG build is open in full unless a test
   says otherwise (LUMEN_TEST_ACCESS) — a release build must have no way into that. Every test switch
   (LUMEN_TEST_…, LUMEN_FAULTS, -LumenFaults, -LumenResetState) is named in the sources only inside
   #if DEBUG; the built release has none of them in its binary, no exception of App Transport Security
   for the testbed, and a key for the documents of rights (the owner's: the same as the Mac release's).

    python3 ios/scripts/release_rules.py [ios-dir] [--app Lumen.app] [--release-app Lumen.app]
        -> exit 0, or 1 listing each breach. --app: any build's Info.plist (rules 1–3).
           --release-app: a Release build, its binary and Info.plist too (rule 4).

What is scanned: every string literal of the app's Swift sources (ios/Lumen, without Debug/, which a
release build does not contain) — texts, screen names, accessibility labels and identifiers alike —,
the Info.plist values in project.yml, any .strings file, the product description's section of
LIMITATIONS.md, the App Store's card (AppStore/metadata), and with --app every string of the built Info.plist. ios/scripts/test_release_rules.py plants each word, and each App-Bound breach (the reds).
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
# Keys anyone knows: the development server's (the server's CONTRACT.md §7.2), the test vectors'
# (its docs/entitlement-test-vectors.json; the lead, 10 November) and the testbed's stand-in's
# (ios/testbed/account.py --key) — each by its id and by the key itself.
KNOWN_KEYS = {
    "the development server's key": ("445c6300da0205b1", "/+/sbiH55nmy+2gRqQz12E0spl9L/YDWvjnecaN2M1c="),
    "the test vectors' key": ("eaae27700d8b08a3", "iiZ+mIsNmJjmQ/RMlcV8EFhoNUtJoTZrsP52U52qcf4="),
    "the testbed's key": ("cbbc653cdb8bd787", "dNOl9JtGQJg6VOEIn3+1dscg5hWYkx9XUqm+qJ5CnZc="),
}


# The switches only tests use. None may be read by a release build.
SWITCH = re.compile(r'LUMEN_TEST_[A-Z_]+|LUMEN_FAULTS|-LumenFaults|-LumenResetState')


# Rule 5 (the owner, 10 November): nothing in the app offers a plan, names where to buy one or leads
# to the site's prices. A plan is named only as the paid plan a person already has.
OFFER = re.compile(r"pricing|выбрать тариф|тариф\w* на сайте|тарифы|купить|оплатит", re.IGNORECASE)
# The same in the English table (its words are too common to look for among the sources' identifiers).
OFFER_ENGLISH = re.compile(r"choose a plan|\bbuy\b|purchase|\bplans\b|\bprices?\b|pricing", re.IGNORECASE)


# What App Store Connect takes in each field of the card, in characters.
LISTING_LIMITS = {"name.txt": 30, "subtitle.txt": 30, "promotional_text.txt": 170, "keywords.txt": 100,
                  "description.txt": 4000, "release_notes.txt": 4000}


def outside_debug(path):
    """(line number, line) of every line of a Swift file that is not inside #if DEBUG."""
    stack = []   # for each open #if: whether its current branch is compiled only in DEBUG
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        text = line.strip()
        if text.startswith("#if"):
            stack.append(bool(re.match(r"#if\s+DEBUG\b", text)))
        elif text.startswith("#elseif"):
            if stack:
                stack[-1] = False
        elif text.startswith("#else"):
            if stack:
                stack[-1] = False   # the other branch of #if DEBUG is the release's
        elif text.startswith("#endif"):
            if stack:
                stack.pop()
        elif not any(stack):
            yield number, line


def core_files(ios):
    for folder, _, files in os.walk(os.path.join(ios, "LumenCore", "Sources")):
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(folder, name)


def all_app_files(ios):
    for folder, _, files in os.walk(os.path.join(ios, "Lumen")):
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(folder, name)


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
                if OFFER.search(text):
                    found.append((f"{rel}:{number}", "offer", text))
            if known_key_in(line):
                found.append((f"{rel}:{number}", "known-key", f"{known_key_in(line)}: {line.strip()}"))
            code = LITERAL.sub('""', line).split("//", 1)[0]   # the code itself: no literals, no comment
            if "limitsNavigationsToAppBoundDomains" in code and not re.search(r"limitsNavigationsToAppBoundDomains\s*=\s*false", code):
                found.append((f"{rel}:{number}", "app-bound", line.strip()))
    # Rule 4 in the sources (the app's, Debug/ included, and the core's): a test switch is named in
    # code only inside #if DEBUG, and so is the access that opens everything.
    for path in list(all_app_files(ios)) + list(core_files(ios)):
        rel = os.path.relpath(path, ios)
        for number, line in outside_debug(path):
            code = line.split("//", 1)[0]
            for text in LITERAL.findall(code):
                if SWITCH.search(text):
                    found.append((f"{rel}:{number}", "test-switch", line.strip()))
            if re.search(r"\bAccess\.full\b", LITERAL.sub('""', code)):
                found.append((f"{rel}:{number}", "test-switch", "Access.full outside #if DEBUG: " + line.strip()))
    for folder, _, files in os.walk(os.path.join(ios, "Lumen")):
        for name in files:
            if name.endswith(".strings"):
                path = os.path.join(folder, name)
                for number, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
                    for text in LITERAL.findall(line):
                        judge(f"{os.path.relpath(path, ios)}:{number}", text)
                        if OFFER_ENGLISH.search(text):
                            found.append((f"{os.path.relpath(path, ios)}:{number}", "offer", text))
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
    # The App Store's card (ios/AppStore/metadata/<language>/*.txt): what a person reads before the app.
    # The words, and no offer — Apple's guideline 3.1.1 forbids pointing to a purchase outside the app too.
    listing = os.path.join(ios, "AppStore", "metadata")
    for folder, _, files in os.walk(listing):
        for name in sorted(files):
            if not name.endswith(".txt") or name.endswith("_url.txt"):
                continue
            path = os.path.join(folder, name)
            text = open(path, encoding="utf-8").read().rstrip("\n")
            if name in LISTING_LIMITS and len(text) > LISTING_LIMITS[name]:
                found.append((os.path.relpath(path, ios), "length",
                              f"{len(text)} characters, App Store Connect takes {LISTING_LIMITS[name]}"))
            for number, line in enumerate(open(path, encoding="utf-8"), 1):
                where = f"{os.path.relpath(path, ios)}:{number}"
                judge(where, line.strip())
                if OFFER.search(line) or OFFER_ENGLISH.search(line):
                    found.append((where, "offer", line.strip()))
    # The captions over the App Store's pictures (ios/scripts/make_store_cards.mjs).
    captions = os.path.join(ios, "AppStore", "cards", "captions.json")
    if os.path.exists(captions):
        import json
        for language, items in json.load(open(captions, encoding="utf-8")).items():
            for name, lines in items.items():
                for text in lines:
                    judge(f"AppStore/cards/captions.json {language}/{name}", text)
                    if OFFER.search(text) or OFFER_ENGLISH.search(text):
                        found.append((f"AppStore/cards/captions.json {language}/{name}", "offer", text))
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


def scan_release(app):
    """Rule 4 in a built Release app: every breach as (where, rule, text)."""
    found = []
    name = os.path.basename(app)
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)
    binary = os.path.join(app, info.get("CFBundleExecutable", "Lumen"))
    if not os.path.exists(binary) or not os.path.getsize(binary):
        found.append((name, "test-switch", "no binary to check"))
    # Every file of the bundle, not the executable alone: a Debug build keeps its code in a library
    # beside it (Lumen.debug.dylib), and a release must not carry a switch anywhere.
    for folder, _, files in os.walk(app):
        for file in files:
            path = os.path.join(folder, file)
            data = open(path, "rb").read()
            for switch in sorted(set(m.decode() for m in re.findall(SWITCH.pattern.encode(), data))):
                found.append((f"{name}/{os.path.relpath(path, app)}", "test-switch", f"names {switch}"))
    if "lumentest" in repr(info.get("NSAppTransportSecurity", {})):
        found.append((f"{name}/Info.plist NSAppTransportSecurity", "test-switch", "an exception for the testbed (lumentest)"))
    keys = info.get("PBEntitlementPublicKeys")
    if not isinstance(keys, dict) or not keys:
        found.append((f"{name}/Info.plist PBEntitlementPublicKeys", "no-key", "a release trusts no key: nobody could sign in"))
    return found


def main(argv):
    args = argv[1:]
    app = release = None
    if "--app" in args:
        i = args.index("--app")
        app = args[i + 1]
        del args[i:i + 2]
    if "--release-app" in args:
        i = args.index("--release-app")
        release = args[i + 1]
        del args[i:i + 2]
    ios = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    found = scan(ios, app or release)
    if release:
        found += scan_release(release)
    if found:
        print("RELEASE RULES BROKEN:", file=sys.stderr)
        for where, rule, text in found:
            print(f"  [{rule}] {where}: {text}", file=sys.stderr)
        return 1
    print("release rules: none of the positioning words, no App-Bound Domains, no key anyone knows, no test switch outside DEBUG"
          + (f" (and {os.path.basename(app)})" if app else "")
          + (f" (and the release build {os.path.basename(release)}: no test switch in it, a key for the documents of rights)" if release else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
