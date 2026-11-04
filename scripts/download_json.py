#!/usr/bin/env python3
"""download.json — what the website's build reads of a release (the owner: its address, version, size,
SHA-256 and the macOS it needs) — written by a JSON serializer and checked by reading the file back.

    python3 scripts/download_json.py write --dmg Lumen-1.2.3.dmg --version 1.2.3 --build 4 \\
        --url https://dl.lumenbrowser.io/Lumen-1.2.3.dmg --minimum-system 26.0 --out download.json
    python3 scripts/download_json.py check download.json [--dmg Lumen-1.2.3.dmg] [--minimum-system 26.0]

On 3 November 0.1.1's file said `"sizeMB": 17,5,`: release.sh formatted the size with awk's
`printf "%.1f"`, which takes the decimal separator from the locale, and the owner's is Russian — a
file no JSON reader takes, and the site's build would have failed on it. CI's locale is English, so
the environment cannot show it: the check reads the file's content. Here the number is a number to
the serializer, which writes a dot in every locale.

`check` takes the file as the site does — strict JSON (no NaN, no Infinity), one object — and the fields
as the site uses them; with --dmg, the size and the SHA-256 must be that file's; with
--minimum-system, the macOS it needs must be that one. Exit 1 on the first thing wrong, naming it.
"""
import argparse
import hashlib
import json
import os
import re
import sys

FIELDS = ("version", "build", "url", "sizeMB", "sizeBytes", "sha256", "minimumSystem")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def problems(text, dmg=None, minimum_system=None):
    """What is wrong with download.json's text, as the site's build would meet it; empty when nothing."""
    def no_constant(name):
        raise ValueError(f"{name} is not JSON")
    try:
        data = json.loads(text, parse_constant=no_constant)
    except ValueError as error:
        return [f"not JSON: {error}"]
    if not isinstance(data, dict):
        return ["not one JSON object"]
    found = []
    missing = [name for name in FIELDS if name not in data]
    if missing:
        found.append("missing: " + ", ".join(missing))
    extra = sorted(set(data) - set(FIELDS))
    if extra:
        found.append("not of the format: " + ", ".join(extra))
    def is_number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    version, build, url = data.get("version"), data.get("build"), data.get("url")
    if not (isinstance(version, str) and re.fullmatch(r"[0-9]+(\.[0-9]+){1,3}", version)):
        found.append(f"version {version!r} is not a version")
    if not (isinstance(build, str) and re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9}){0,7}", build)):
        found.append(f"build {build!r} is not a build number")
    if not (isinstance(url, str) and url.startswith("https://") and url.endswith(".dmg") and " " not in url):
        found.append(f"url {url!r} is not the https address of a disk image")
    size_mb, size_bytes = data.get("sizeMB"), data.get("sizeBytes")
    if not (is_number(size_mb) and size_mb > 0):
        found.append(f"sizeMB {size_mb!r} is not a positive number")
    if not (isinstance(size_bytes, int) and not isinstance(size_bytes, bool) and size_bytes > 0):
        found.append(f"sizeBytes {size_bytes!r} is not a positive whole number")
    elif is_number(size_mb) and abs(size_mb - size_bytes / 1_000_000) > 0.05:
        found.append(f"sizeMB {size_mb} is not sizeBytes {size_bytes} in megabytes")
    digest = data.get("sha256")
    if not (isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest)):
        found.append(f"sha256 {digest!r} is not a SHA-256 in hex")
    minimum = data.get("minimumSystem")
    if not (isinstance(minimum, str) and re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", minimum)):
        found.append(f"minimumSystem {minimum!r} is not a macOS version")
    elif minimum_system is not None and minimum != minimum_system:
        found.append(f"minimumSystem {minimum} is not the app's {minimum_system}")
    if dmg is not None:
        if size_bytes != os.path.getsize(dmg):
            found.append(f"sizeBytes {size_bytes} is not the image's {os.path.getsize(dmg)}")
        if digest != sha256(dmg):
            found.append("sha256 is not the image's")
    return found


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    write = commands.add_parser("write")
    write.add_argument("--dmg", required=True)
    write.add_argument("--version", required=True)
    write.add_argument("--build", required=True)
    write.add_argument("--url", required=True)
    write.add_argument("--minimum-system", required=True)
    write.add_argument("--out", required=True)
    check = commands.add_parser("check")
    check.add_argument("file")
    check.add_argument("--dmg")
    check.add_argument("--minimum-system")
    arguments = parser.parse_args()

    if arguments.command == "write":
        size = os.path.getsize(arguments.dmg)
        data = {
            "version": arguments.version,
            "build": arguments.build,
            "url": arguments.url,
            # Megabytes as Finder counts them (decimal), one place after the point: a number, which
            # the serializer writes with a dot whatever the locale.
            "sizeMB": round(size / 1_000_000, 1),
            "sizeBytes": size,
            "sha256": sha256(arguments.dmg),
            "minimumSystem": arguments.minimum_system,
        }
        with open(arguments.out, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        return 0

    with open(arguments.file, encoding="utf-8") as handle:
        text = handle.read()
    found = problems(text, dmg=arguments.dmg, minimum_system=arguments.minimum_system)
    for problem in found:
        print(f"error: {arguments.file}: {problem}", file=sys.stderr)
    if found:
        return 1
    print(f"download.json: valid JSON, every field as the website reads it ({arguments.file})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
