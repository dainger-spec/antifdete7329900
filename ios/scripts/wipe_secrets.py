#!/usr/bin/env python3
"""Wipe secrets from the files of a folder before they are uploaded from a public repository:

    python3 ios/scripts/wipe_secrets.py <folder> <ENVIRONMENT NAME>...

Every occurrence of each named variable's value — as it is, in lower and in upper case, and
percent-encoded, escaped as a string, and without the spaces around it — is replaced with "***" in
every file of the folder, whatever the file is. The values are never printed; only how many files
were changed. `--check <folder> <NAME>...` changes nothing and fails when any form is still in a file
(or a name is not set), naming the files. A variable that is not set is passed
over (and said so). `--selftest` checks the script on a folder it makes.
"""
import json, os, sys, tempfile, urllib.parse


def forms(value):
    """The value as a log may hold it: as it is and without the spaces or line end a secret pasted
    into GitHub can carry (run 133: XCUITest's "Type '…'" lines kept the account, the secret's own
    form was not found in them), in lower and upper case, percent-encoded, escaped as a string."""
    found = set()
    for base in {value, value.strip()}:
        for v in (base, base.lower(), base.upper()):
            found |= {v, urllib.parse.quote(v, safe=""), json.dumps(v)[1:-1], v.replace("'", "\\'")}
    return sorted((f.encode() for f in found if len(f) >= 4), key=len, reverse=True)


def left(folder, values):
    """The files of the folder that still hold any form of a value (their paths, never the value)."""
    found = []
    for parent, _, files in os.walk(folder):
        for name in files:
            path = os.path.join(parent, name)
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            if any(form in data for value in values for form in forms(value)):
                found.append(os.path.relpath(path, folder))
    return found


def wipe(folder, values):
    changed = 0
    for parent, _, files in os.walk(folder):
        for name in files:
            path = os.path.join(parent, name)
            try:
                data = open(path, "rb").read()
            except OSError:
                continue
            clean = data
            for value in values:
                for form in forms(value):
                    clean = clean.replace(form, b"***")
            if clean != data:
                open(path, "wb").write(clean)
                changed += 1
    return changed


def selftest():
    with tempfile.TemporaryDirectory() as folder:
        os.mkdir(os.path.join(folder, "deep"))
        open(os.path.join(folder, "a.txt"), "w").write("typed Someone@Example.org and pass+Word1\nsomeone@example.org again\n")
        open(os.path.join(folder, "deep", "b.log"), "wb").write(b"\x00\x01q=someone%40example.org&p=pass%2BWord1\x02")
        open(os.path.join(folder, "c.txt"), "w").write("nothing here\n")
        open(os.path.join(folder, "e.txt"), "w").write("Type 'someone@example.org' into \"signInEmail\"\n")
        # The secrets as GitHub may keep them: with the line end of a paste.
        changed = wipe(folder, ["Someone@Example.org\n", " pass+Word1"])
        left = b"".join(open(os.path.join(p, n), "rb").read() for p, _, names in os.walk(folder) for n in names).lower()
        ok = changed == 3 and b"someone" not in left and b"pass" not in left and b"nothing here" in left
        ok = ok and not globals()["left"](folder, ["Someone@Example.org\n", " pass+Word1"])
        # The red: without the wipe the values are there.
        open(os.path.join(folder, "d.txt"), "w").write("pass+Word1")
        red = b"pass+word1" in open(os.path.join(folder, "d.txt"), "rb").read().lower()
        red = red and globals()["left"](folder, ["pass+Word1"]) == ["d.txt"]
        print("wipe_secrets selftest: " + ("ok" if ok and red else "FAILED"))
        return 0 if ok and red else 1


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    check = argv[1:2] == ["--check"]
    if check:
        argv = argv[:1] + argv[2:]
    if len(argv) < 3:
        print(__doc__); return 2
    values = []
    for name in argv[2:]:
        value = os.environ.get(name, "")
        if len(value) < 4:
            print(f"wipe: {name} is not set (or too short to look for) — passed over")
        else:
            values.append(value)
    if not os.path.isdir(argv[1]):
        print(f"wipe: no folder {argv[1]} — nothing to wipe"); return 0
    if check:
        found = left(argv[1], values)
        print(f"wipe check: {len(found)} file(s) still hold a secret" + (": " + ", ".join(found) if found else ""))
        return 1 if found or len(values) < len(argv) - 2 else 0
    print(f"wipe: {wipe(argv[1], values)} file(s) changed, {len(values)} value(s) looked for")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
