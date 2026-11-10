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
from release_rules import WORDS, scan, scan_release  # noqa: E402

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
    shutil.copytree(os.path.join(IOS, "LumenCore", "Sources"), os.path.join(root, "LumenCore", "Sources"))
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
    plistlib.dump({"CFBundleIdentifier": "io.lumenbrowser.ios", "PBEntitlementPublicKeys": {"63a9a50f8cc6f129": "bOCnaE4nVmmeqieu9CNIo0AY86OOYqe65OwSJbTwYn0="}}, f)
check("the production key in the built app is not taken for a known one", not any(f[1] == "known-key" for f in scan(IOS, app)))

# Nothing offers a plan or leads to the site's prices.
for what, line in [
    ("a button to the site's plans", 'Button("Выбрать тариф на сайте") {}'),
    ("the site's pricing page", 'let url = site.appendingPathComponent("pricing")'),
    ("a list of plans", 'Section("Тарифы") {}'),
    ("an offer to buy", 'Text("Купить можно на сайте")'),
]:
    check(f"red — {what}: found", any(f[1] == "offer" for f in scan(planted(line))))
root = planted('let row = Text("Сессии")')
with open(os.path.join(root, "Lumen", "Resources", "en.lproj", "Localizable.strings"), "a", encoding="utf-8") as f:
    f.write('"Выбор" = "Choose a plan on the website";\n')
check("red — an offer in the English table: found", any(f[1] == "offer" for f in scan(root)))
check("a paid plan's own name is allowed", not any(f[1] == "offer" for f in scan(planted('Text("Тариф: Профессиональный")'))))

# No test switch in a release: in the sources outside #if DEBUG, and in a built release.
for what, line, file in [
    ("the plan's switch read outside #if DEBUG", 'let plan = ProcessInfo.processInfo.environment["LUMEN_TEST_ACCESS"]', "Lumen/AppModel.swift"),
    ("the faults read outside #if DEBUG (the core)", 'let faults = ProcessInfo.processInfo.environment["LUMEN_FAULTS"]', "LumenCore/Sources/LumenCore/Access.swift"),
    ("the reset argument read outside #if DEBUG", 'let reset = CommandLine.arguments.contains("-LumenResetState")', "Lumen/LumenApp.swift"),
    ("the access that opens everything used outside #if DEBUG", "let open = Access.full", "Lumen/AppModel.swift"),
    ("a switch in the release branch of #if DEBUG", '#if DEBUG\nlet a = 1\n#else\nlet b = ProcessInfo.processInfo.environment["LUMEN_TEST_SITE_URL"]\n#endif', "Lumen/AppModel.swift"),
]:
    check(f"red — {what}: found", any(f[1] == "test-switch" for f in scan(planted(line, file))))
inside = scan(planted('#if DEBUG\nlet plan = ProcessInfo.processInfo.environment["LUMEN_TEST_ACCESS"]\nlet open = Access.full\n#endif', "Lumen/AppModel.swift"))
check("a switch inside #if DEBUG is allowed", not any(f[1] == "test-switch" for f in inside), repr(inside[:2]))


def built(binary, info):
    """A stand-in for a built app: its binary's bytes and its Info.plist."""
    root = tempfile.mkdtemp(suffix=".app")
    with open(os.path.join(root, "Lumen"), "wb") as f:
        f.write(binary)
    with open(os.path.join(root, "Info.plist"), "wb") as f:
        plistlib.dump(dict({"CFBundleIdentifier": "io.lumenbrowser.ios", "CFBundleExecutable": "Lumen"}, **info), f)
    return root


OWNERS = {"PBEntitlementPublicKeys": {"63a9a50f8cc6f129": "bOCnaE4nVmmeqieu9CNIo0AY86OOYqe65OwSJbTwYn0="}}
check("a release with a key and no switch passes", not scan_release(built(b"\x00code\x00Lumen\x00", OWNERS)), "")
for what, app_dir, rule in [
    ("the plan's switch in the release's binary", built(b"\x00LUMEN_TEST_ACCESS\x00", OWNERS), "test-switch"),
    ("the faults in the release's binary", built(b"\x00LUMEN_FAULTS\x00-LumenFaults\x00", OWNERS), "test-switch"),
    ("the testbed's exception in the release's Info.plist",
     built(b"\x00", dict(OWNERS, NSAppTransportSecurity={"NSExceptionDomains": {"account.lumentest": {"NSExceptionAllowsInsecureHTTPLoads": True}}})), "test-switch"),
    ("a release that trusts no key", built(b"\x00", {"PBEntitlementPublicKeys": {}}), "no-key"),
    ("a release without the keys' entry", built(b"\x00", {}), "no-key"),
]:
    check(f"red — {what}: found", any(f[1] == rule for f in scan_release(app_dir)))

allowed = scan(planted('let x = [Text("Сессии"), Text("Изоляция сессий"), Text("Профиль устройства"), Text("Тестирование сайтов"), Text("Доступно на тарифе выше")]'))
check("the app's own words are allowed (сессии, изоляция, профиль устройства, тестирование)", not allowed, repr(allowed))

print(f"{failures} failed")
sys.exit(1 if failures else 0)
