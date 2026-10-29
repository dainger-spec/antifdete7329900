#!/usr/bin/env python3
"""The UI's strings are complete in both languages, and none is written into the code.

    python3 scripts/check_localization.py

Fails (exit code 1) when:

* `Resources/ru.lproj` and `Resources/en.lproj` do not have the same keys, a key appears twice in
  one table, or a key's format specifiers (`%@`, `%d`, `%1$@`, …) differ between the languages —
  `String(format:)` with the wrong ones crashes or prints garbage;
* a key used in the code (`L("key")`) is in neither table, or a key built at run time
  (`L("prefix.\\(value)")`) has no key starting with its prefix;
* a string a user would read is written into the code instead of going through `L(...)`: the
  text of `Text`, `Button`, `Label`, `Toggle`, `TextField`, `Section`, `Menu`, `Picker`, `Link`,
  `.help`, `.navigationTitle`, `.accessibilityLabel`/`Hint`/`Value`, `toolTip`, `title`,
  `messageText`, `informativeText`, `placeholder…`, `prompt`, `addItem(withTitle:)` and the
  toolbar helpers. A literal that is not text (an SF Symbol name, a glyph, a profile's own name
  interpolated, a brand) is marked on its line with `// l10n: not text`.

Unused keys are listed, not failed on. Code that is never shown to a user (the self-test, the
CI harnesses) is not looked at.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLES = {lang: os.path.join(ROOT, "Resources", f"{lang}.lproj", "Localizable.strings") for lang in ("ru", "en")}
SOURCES = os.path.join(ROOT, "Sources", "PrivacyBrowser")
# Never shown to a user of the app: test and CI harnesses.
NOT_UI = {"SelfTest.swift", "SiteCapture.swift", "UTunRelayHarness.swift"}
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA%]")
USE = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"\)')
UI_TEXT = re.compile(
    r'(?:\b(?:Text|Button|Label|Toggle|TextField|SecureField|Section|Menu|Picker|Link)\('
    r'|\btoolbarButton\(\s*"[^"]*"\s*,'  # a toolbar helper's symbol name comes first
    r'|\baccessibilityDescription:\s*'
    r'|\.(?:help|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue)\('
    r'|\b(?:toolTip|title|messageText|informativeText|placeholderString|prompt)\s*=\s*'
    r'|\b(?:title|placeholder|prompt|withTitle):\s*)'
    r'\s*"((?:[^"\\]|\\.)*)"')
WORDS = re.compile(r"[A-Za-zА-Яа-яЁё]{2,}")


def read_table(path):
    entries, problems = {}, []
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    # Block comments may hold anything; only key = value lines matter.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.strip().startswith("//"):
            continue
        match = ENTRY.match(line)
        if not match:
            problems.append(f"{os.path.relpath(path, ROOT)}:{number}: not a \"key\" = \"value\"; line: {line.strip()[:80]}")
            continue
        key, value = match.groups()
        if key in entries:
            problems.append(f"{os.path.relpath(path, ROOT)}:{number}: duplicate key {key}")
        entries[key] = value
    return entries, problems


def specifiers(value):
    found = [s for s in SPECIFIER.findall(value) if s != "%%"]
    # Positional and plain forms of the same list compare equal: %1$@ %2$d ≡ %@ %d.
    return sorted(re.sub(r"\d+\$", "", s) for s in found)


def main():
    failures = []
    tables = {}
    for lang, path in TABLES.items():
        entries, problems = read_table(path)
        tables[lang] = entries
        failures += problems
    ru, en = tables["ru"], tables["en"]
    for key in sorted(set(ru) - set(en)):
        failures.append(f"key only in ru: {key}")
    for key in sorted(set(en) - set(ru)):
        failures.append(f"key only in en: {key}")
    for key in sorted(set(ru) & set(en)):
        if specifiers(ru[key]) != specifiers(en[key]):
            failures.append(f"format specifiers differ for {key}: ru {specifiers(ru[key])} vs en {specifiers(en[key])}")

    used, dynamic = set(), set()
    for folder, _, files in os.walk(SOURCES):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, ROOT)
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().splitlines()
            for number, line in enumerate(lines, 1):
                code = line.split("//", 1)[0] if not line.strip().startswith("//") else ""
                for key in USE.findall(code):
                    if "\\(" in key:
                        dynamic.add(key.split("\\(", 1)[0])
                    else:
                        used.add(key)
                        if key not in ru and key not in en:
                            failures.append(f"{relative}:{number}: L(\"{key}\") is in neither strings table")
                if name in NOT_UI or "l10n: not text" in line or line.strip().startswith("//"):
                    continue
                for literal in UI_TEXT.findall(code):
                    if WORDS.search(literal) and not literal.startswith(("http://", "https://")):
                        failures.append(f"{relative}:{number}: text a user reads is not localized: \"{literal}\" "
                                        "(use L(\"key\"), or mark the line `// l10n: not text`)")
    for prefix in sorted(dynamic):
        if not any(key.startswith(prefix) for key in ru):
            failures.append(f"no key starts with {prefix!r}, which the code builds keys from")
    unused = sorted(key for key in ru if key not in used and not any(key.startswith(p) for p in dynamic))
    print(f"localization: {len(ru)} keys in ru, {len(en)} in en, {len(used)} used directly, "
          f"{len(dynamic)} key prefixes built at run time, {len(unused)} not used")
    if unused:
        print("  not used (listed, not failed on): " + ", ".join(unused[:80]) + (" …" if len(unused) > 80 else ""))
    if failures:
        for failure in failures:
            print("FAIL " + failure)
        return 1
    print("localization: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
