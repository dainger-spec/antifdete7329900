#!/usr/bin/env python3
"""The account's secrets come out as text in a few places only, each named with why.

    python3 scripts/check_account_key.py [source root]     (default: Sources)
    python3 scripts/check_account_key.py --self-check       (the check against planted lines)

A license key bought without registration is the whole account for whoever holds it: no email, no
password, nothing else. The owner (1 November): "the key is kept as carefully as the master password:
not in the settings, not in the logs, not in error reports". The app's types for it — `AccountKey`, and
`ServerToken` for the server's tokens — never say themselves: interpolated, printed, dumped or
mirrored they show "LMK-…" or "lmd_…". Their text comes out only through `unredacted()`, and this
fails on any call of it outside the files in ALLOWED, each with why. Comments do not count.

`--self-check` runs the same scan over planted lines — the forbidden calls each in a file of their
own, and the allowed forms — and fails unless every forbidden one is found and no allowed one is: a
scan that cannot fail checks nothing.
"""
import os
import re
import sys
import tempfile

CALL = re.compile(r"\.unredacted\s*\(")

ALLOWED = {
    os.path.join("BrowserCore", "License", "AccountKey.swift"):
        "the key's own type",
    os.path.join("BrowserCore", "License", "AccountRecord.swift"):
        "the token's own type",
    os.path.join("BrowserCore", "License", "AccountAPI.swift"):
        "the requests: the key in a request's body (never in an address), the key's lookups",
    os.path.join("BrowserCore", "License", "AccountKeyVault.swift"):
        "the vault's file that keeps the key, encrypted under the vault's key",
    os.path.join("BrowserCore", "License", "AccountSessionVault.swift"):
        "the vault's file that keeps the session's token between runs, encrypted under the vault's key (APP-11)",
    os.path.join("PrivacyBrowser", "App", "Account", "AccountHTTP.swift"):
        "the transport: a token in the Authorization header",
    os.path.join("PrivacyBrowser", "UI", "NewKeyView.swift"):
        "the new key shown once after a replacement, and copied at the person's click (CONTRACT §11.1, key.replaced)",
}


def scan(root):
    """(path, line number, line) for every call outside ALLOWED."""
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
                    if CALL.search(code):
                        found.append((relative, number, line.strip()))
    return found


def self_check():
    forbidden = {
        "a.swift": 'log.notice("key \\(key.unredacted(), privacy: .public)")',
        "b.swift": 'UserDefaults.standard.set(key.unredacted(), forKey: "licenseKey")',
        "c.swift": 'let text = token .unredacted ()',
        "d.swift": '    Text(account.key.unredacted())',
    }
    allowed = {
        "e.swift": '// key.unredacted() said in a comment only',
        "f.swift": 'Text(verbatim: "\\(key)")',
        "g.swift": 'let shown = String(describing: token)',
    }
    with tempfile.TemporaryDirectory() as root:
        for name, line in {**forbidden, **allowed}.items():
            with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
                handle.write(line + "\n")
        # An allowed file, where the call is expected.
        allowed_path = os.path.join(root, list(ALLOWED)[2])
        os.makedirs(os.path.dirname(allowed_path), exist_ok=True)
        with open(allowed_path, "w", encoding="utf-8") as handle:
            handle.write('body["key"] = key.unredacted()\n')
        flagged = {path for path, *_ in scan(root)}
    missed = sorted(set(forbidden) - flagged)
    wrong = sorted(flagged - set(forbidden))
    if missed or wrong:
        print(f"account key self-check FAILED: forbidden not found {missed}, allowed flagged {wrong}")
        return 1
    print(f"account key self-check: {len(forbidden)} forbidden calls found, {len(allowed) + 1} allowed forms not")
    return 0


def main():
    if "--self-check" in sys.argv[1:]:
        return self_check()
    root = next((argument for argument in sys.argv[1:] if not argument.startswith("--")), "Sources")
    found = scan(root)
    for path, number, line in found:
        print(f"{path}:{number}: the account's key or a token as text outside its places: {line}")
    if found:
        print(f"\n{len(found)} call(s) take the key's or a token's text where it may end in a log, a setting or a "
              "report: keep it in the request or the vault (scripts/check_account_key.py, ALLOWED).")
        return 1
    print(f"account key: its text only in its {len(ALLOWED)} places, each with why")
    return 0


if __name__ == "__main__":
    sys.exit(main())
