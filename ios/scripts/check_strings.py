#!/usr/bin/env python3
"""The app's two languages (the owner, 10 November: Russian and English), checked in the sources.

A text the person reads is written once, in Russian, inside L(…) (LumenCore/Localization.swift); its
English is in the String Catalog, Lumen/Resources/Localizable.xcstrings, under the same words (Xcode
compiles it into each language's table; the source language is Russian).

    python3 ios/scripts/check_strings.py --set "<Russian>" "<English>"   -> adds or changes one text
    python3 ios/scripts/check_strings.py --prune                         -> removes the texts no code uses

    python3 ios/scripts/check_strings.py [ios-dir]      -> exit 0, or 1 listing each breach
    python3 ios/scripts/check_strings.py --selftest     -> each breach planted, each must be found

Breaches: a Russian literal outside L(…) (it would stay Russian on an English iPhone); a text with no
English; an English with another number of %@ than its Russian, or with Russian letters in it; an
English no text uses. Debug/ (not in a release) and comments are not looked at.
"""
import json
import os
import re
import shutil
import sys
import tempfile

CYRILLIC = re.compile("[А-Яа-яЁё]")
LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def sources(ios):
    for base in ("Lumen", os.path.join("LumenCore", "Sources")):
        for folder, dirs, files in os.walk(os.path.join(ios, base)):
            dirs[:] = [d for d in dirs if d != "Debug"]
            for name in files:
                if name.endswith(".swift"):
                    yield os.path.join(folder, name)


CATALOG = os.path.join("Lumen", "Resources", "Localizable.xcstrings")


def load_catalog(ios):
    path = os.path.join(ios, CATALOG)
    if not os.path.exists(path):
        return None
    return json.load(open(path, encoding="utf-8"))


def save_catalog(ios, catalog):
    with open(os.path.join(ios, CATALOG), "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


def table(ios):
    """Russian text -> its English, as the catalog has it."""
    catalog = load_catalog(ios) or {}
    entries = {}
    for key, entry in catalog.get("strings", {}).items():
        unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
        if "value" in unit:
            entries[key] = unit["value"]
    return entries


def scan(ios):
    found = []
    english = table(ios)
    if not english:
        found.append((CATALOG, "no English in the String Catalog"))
    used = set()
    for path in sources(ios):
        rel = os.path.relpath(path, ios)
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            code = line.split("//", 1)[0]
            for m in LITERAL.finditer(code):
                text = m.group(1)
                inside = code[:m.start()].rstrip().endswith("L(")
                if inside:
                    used.add(text)
                    if text not in english:
                        found.append((f"{rel}:{number}", f"no English for: {text}"))
                elif CYRILLIC.search(text):
                    found.append((f"{rel}:{number}", f"a Russian text outside L(…): {text}"))
    for key, value in english.items():
        if key == "__language":
            continue
        if key.count("%@") != value.count("%@"):
            found.append(("Localizable.xcstrings", f"another number of %@ in the English of: {key}"))
        if CYRILLIC.search(value):
            found.append(("Localizable.xcstrings", f"Russian letters in the English of: {key}"))
        if key not in used:
            found.append(("Localizable.xcstrings", f"an English no text uses: {key}"))
    if english.get("__language") != "en":
        found.append(("Localizable.xcstrings", "the catalog does not name its language (__language = en)"))
    return found


def selftest(ios):
    failures = 0

    def planted(change):
        root = tempfile.mkdtemp()
        shutil.copytree(os.path.join(ios, "Lumen"), os.path.join(root, "Lumen"))
        shutil.copytree(os.path.join(ios, "LumenCore", "Sources"), os.path.join(root, "LumenCore", "Sources"))
        change(root)
        return scan(root)

    def add(file, line):
        return lambda root: open(os.path.join(root, file), "a", encoding="utf-8").write("\n" + line + "\n")

    def edit(key, value, extra=None):
        def change(root):
            catalog = load_catalog(root)
            assert key in catalog["strings"], key
            catalog["strings"][key]["localizations"]["en"]["stringUnit"]["value"] = value
            if extra:
                catalog["strings"][extra] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Extra"}}}}
            save_catalog(root, catalog)
        return change

    cases = [
        ("a Russian text outside L(…)", add("Lumen/Views/SessionsView.swift", 'let t = Text("Новый экран")'), "outside L"),
        ("a text with no English", add("Lumen/Views/SessionsView.swift", 'let t = Text(L("Совсем новый текст"))'), "no English for"),
        ("an English with one %@ less", edit("Открывали %@", "Opened"), "number of %@"),
        ("an English left in Russian", edit("Сессии", "Сессии"), "Russian letters"),
        ("an English no text uses", edit("Сессии", "Sessions", extra="Лишний"), "no text uses"),
    ]
    clean = scan(ios)
    print(("ok    " if not clean else "FAIL  ") + "the app as it is: every text has its English" + (f" — {clean[:3]}" if clean else ""))
    failures += 1 if clean else 0
    for what, change, sign in cases:
        hit = any(sign in message for _, message in planted(change))
        print(("ok    " if hit else "FAIL  ") + f"red — {what}: found")
        failures += 0 if hit else 1
    print(f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ios = os.path.abspath(args[0] if args else here)
    if "--selftest" in sys.argv:
        sys.exit(selftest(ios))
    if "--set" in sys.argv:
        i = sys.argv.index("--set")
        russian, english = sys.argv[i + 1], sys.argv[i + 2]
        ios = here and os.path.abspath(here)
        catalog = load_catalog(ios)
        catalog["strings"][russian] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": english}}}}
        save_catalog(ios, catalog)
        sys.exit(0)
    if "--prune" in sys.argv:
        catalog = load_catalog(ios)
        unused = [m.split(": ", 1)[1] for _, m in scan(ios) if m.startswith("an English no text uses: ")]
        for key in unused:
            catalog["strings"].pop(key, None)
        save_catalog(ios, catalog)
        print(f"removed {len(unused)} texts no code uses")
        sys.exit(0)
    breaches = scan(ios)
    for where, message in breaches:
        print(f"  {where}: {message}", file=sys.stderr)
    if breaches:
        print("TEXTS: not every text has both languages", file=sys.stderr)
        sys.exit(1)
    print(f"texts: {len(table(ios)) - 1} texts, each in Russian and in English")
