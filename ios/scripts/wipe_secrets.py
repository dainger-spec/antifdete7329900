#!/usr/bin/env python3
"""Wipe secrets from the files of a folder before they are uploaded from a public repository:

    python3 ios/scripts/wipe_secrets.py <folder> <ENVIRONMENT NAME>...

Every occurrence of each named variable's value — as it is, in lower and in upper case, and
percent-encoded — is replaced with "***" in every file of the folder, whatever the file is. The
values are never printed; only how many files were changed. A variable that is not set is passed
over (and said so). `--selftest` checks the script on a folder it makes.
"""
import os, sys, tempfile, urllib.parse


def forms(value):
    found = {value, value.lower(), value.upper(), urllib.parse.quote(value, safe=""), urllib.parse.quote(value.lower(), safe="")}
    return sorted((f.encode() for f in found if f), key=len, reverse=True)


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
        changed = wipe(folder, ["Someone@Example.org", "pass+Word1"])
        left = b"".join(open(os.path.join(p, n), "rb").read() for p, _, names in os.walk(folder) for n in names).lower()
        ok = changed == 2 and b"someone" not in left and b"pass" not in left and b"nothing here" in left
        # The red: without the wipe the values are there.
        open(os.path.join(folder, "d.txt"), "w").write("pass+Word1")
        red = b"pass+word1" in open(os.path.join(folder, "d.txt"), "rb").read().lower()
        print("wipe_secrets selftest: " + ("ok" if ok and red else "FAILED"))
        return 0 if ok and red else 1


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
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
    print(f"wipe: {wipe(argv[1], values)} file(s) changed, {len(values)} value(s) looked for")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
