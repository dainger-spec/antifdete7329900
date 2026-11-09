#!/usr/bin/env python3
"""release_rules.py on planted breaches (the reds) and on the app as it is (green).

    python3 ios/scripts/test_release_rules.py

Each red copies the app's sources, plants one breach of the owner's rules (8 November, second version)
and must be found: every word of the list, as a text, a screen's name or an Info.plist value, and each
App-Bound Domains breach. The words the app is meant to use ("сессии", "изоляция", "профиль
устройства", "тестирование") must not be.
"""
import os
import plistlib
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from release_rules import WORDS, scan  # noqa: E402

failures = 0


def check(what, ok, detail=""):
    global failures
    print(("ok    " if ok else "FAIL  ") + what + (f" — {detail}" if detail and not ok else ""))
    failures += 0 if ok else 1


def planted(line, file="Lumen/Views/SessionsView.swift"):
    """A copy of the app's sources with `line` added to `file`."""
    root = tempfile.mkdtemp()
    shutil.copytree(os.path.join(IOS, "Lumen"), os.path.join(root, "Lumen"))
    shutil.copy(os.path.join(IOS, "project.yml"), os.path.join(root, "project.yml"))
    with open(os.path.join(root, file), "a", encoding="utf-8") as f:
        f.write("\n" + line + "\n")
    return root


found = scan(IOS)
check("the app as it is: no breach", not found, repr(found[:3]))

# Every word, in a sentence as it would be written, and where it would be.
SENTENCES = {
    "антидетект": 'let title = Text("Антидетект-браузер для команд")',
    "обход": 'let note = Text("Обход блокировок сайтов")',
    "фингерпринт": 'let section = Section("Фингерпринт") {}',
    "подмена отпечатка": 'let row = Text("Подмена отпечатка браузера")',
    "мультиаккаунт": '.navigationTitle("Мультиаккаунтинг")',
    "отпечаток": 'let row = Text("Отпечаток: шум")',
    "подмена": 'let row = Toggle("Подменять часовой пояс", isOn: $on)',
    "antidetect": 'let title = Text("Anti-detect sessions")',
    "fingerprint": '.accessibilityLabel("Fingerprint settings")',
    "spoof": 'let row = Text("Spoof the canvas")',
    "bypass": 'let row = Text("Bypass restrictions")',
    "multi-account": 'let row = Text("Multi-account made easy")',
}
check("every word of the list has its red", set(SENTENCES) == set(WORDS), f"{set(WORDS) ^ set(SENTENCES)}")
for word, line in SENTENCES.items():
    hits = [f for f in scan(planted(line)) if f[1] == f"word «{word}»"]
    check(f"red — «{word}» in the sources: found", bool(hits), f"nothing found for {line!r}")

root = planted('let row = Text("Сессии")')
shutil.copy(os.path.join(IOS, "LIMITATIONS.md"), os.path.join(root, "LIMITATIONS.md"))
text = open(os.path.join(root, "LIMITATIONS.md"), encoding="utf-8").read()
open(os.path.join(root, "LIMITATIONS.md"), "w", encoding="utf-8").write(
    text.replace("## Для описания продукта\n", "## Для описания продукта\n\nЛучший антидетект для iPhone.\n", 1))
check("red — a word in the product description (LIMITATIONS.md): found", any(f[0].startswith("LIMITATIONS.md") for f in scan(root)))
hits = scan(planted("        NSLocalNetworkUsageDescription: Мультиаккаунт видит устройства в сети", "project.yml"))
check("red — a word in an Info.plist value (project.yml): found", any(f[1].startswith("word") for f in hits))
app = tempfile.mkdtemp(suffix=".app")
with open(os.path.join(app, "Info.plist"), "wb") as f:
    plistlib.dump({"CFBundleIdentifier": "io.lumenbrowser.ios", "CFBundleDisplayName": "Lumen Антидетект"}, f)
check("red — a word in the built app's Info.plist: found", any(f[1].startswith("word") for f in scan(IOS, app)))

for what, line, file in [
    ("WKAppBoundDomains declared", "        WKAppBoundDomains: [web.telegram.org]", "project.yml"),
    ("limitsNavigationsToAppBoundDomains turned on", "configuration.limitsNavigationsToAppBoundDomains = true", "Lumen/Views/SessionsView.swift"),
]:
    check(f"red — {what}: found", any(f[1] == "app-bound" for f in scan(planted(line, file))))
with open(os.path.join(app, "Info.plist"), "wb") as f:
    plistlib.dump({"CFBundleIdentifier": "io.lumenbrowser.ios", "WKAppBoundDomains": ["web.telegram.org"]}, f)
check("red — the built app declares WKAppBoundDomains: found", any(f[1] == "app-bound" for f in scan(IOS, app)))

# The account: a key anyone knows, wherever it could be planted.
from release_rules import KNOWN_KEYS  # noqa: E402
for name, (key_id, key) in KNOWN_KEYS.items():
    hits = scan(planted(f"        PBEntitlementPublicKeys: {{{key_id}: {key}}}", "project.yml"))
    check(f"red — {name} in project.yml: found", any(f[1] == "known-key" for f in hits))
    hits = scan(planted(f'let trusted = ["{key_id}": "{key}"]', "Lumen/Account/AccountClient.swift"))
    check(f"red — {name} in the sources: found", any(f[1] == "known-key" for f in hits))
    with open(os.path.join(app, "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": "io.lumenbrowser.ios", "PBEntitlementPublicKeys": {key_id: key}}, f)
    check(f"red — {name} in the built app's Info.plist: found", any(f[1] == "known-key" for f in scan(IOS, app)))
with open(os.path.join(app, "Info.plist"), "wb") as f:
    plistlib.dump({"CFBundleIdentifier": "io.lumenbrowser.ios", "PBEntitlementPublicKeys": {"eaae27700d8b08a3": "iiZ+mIsNmJjmQ/RMlcV8EFhoNUtJoTZrsP52U52qcf4="}}, f)
check("another key in the built app is not taken for a known one", not any(f[1] == "known-key" for f in scan(IOS, app)))

allowed = scan(planted('let x = [Text("Сессии"), Text("Изоляция сессий"), Text("Профиль устройства"), Text("Тестирование сайтов"), Text("Доступно на тарифе выше")]'))
check("the app's own words are allowed (сессии, изоляция, профиль устройства, тестирование)", not allowed, repr(allowed))

print(f"{failures} failed")
sys.exit(1 if failures else 0)
