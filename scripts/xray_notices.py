#!/usr/bin/env python3
"""Writes Resources/Xray/NOTICE.txt: what Lumen ships of Xray-core, where its source is, and the
licence of every piece of code in the binary (docs/TUNNEL.md, "Links"; docs/LICENSING.md).

    scripts/xray_notices.py --source build/xray-src/Xray-core --binary build/xray-src/out/xray-darwin-arm64 \
        --lock scripts/xray.lock --out Resources/Xray/NOTICE.txt [--check]

Run by `scripts/build-xray.sh --record`. The modules are the ones the binary itself names (its build
information, `go version -m`), each with the licence files at the root of that module as Go fetched
and verified it; the Go standard library with the toolchain's licence. A module without a licence file
fails the run: nothing is shipped whose terms are not written down. `--check` compares with the file
as it is instead of writing it (CI: the notices match the pin).

Xray-core is under the Mozilla Public License 2.0, a file-level copyleft: Lumen ships it unmodified, as
a separate executable, and says here where its source form is (MPL 2.0 §3.2(a)).
"""
import argparse
import os
import subprocess
import sys

LICENSE_NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "PATENTS")


def lock_values(path):
    values = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return values


def module_cache_path(cache, module, version):
    # Go's module cache spells an upper-case letter as "!" and its lower case.
    escaped = "".join("!" + c.lower() if c.isupper() else c for c in module)
    return os.path.join(cache, escaped + "@" + version)


def licence_files(directory):
    found = []
    for name in sorted(os.listdir(directory)):
        upper = name.upper()
        if any(upper == base or upper.startswith(base + ".") or upper.startswith(base + "-") for base in LICENSE_NAMES):
            path = os.path.join(directory, name)
            if os.path.isfile(path):
                found.append(path)
    return found


def binary_modules(binary, environment):
    output = subprocess.run(["go", "version", "-m", binary], capture_output=True, text=True, check=True, env=environment).stdout
    modules = []
    go_version = None
    for index, line in enumerate(output.splitlines()):
        if index == 0:
            # "<binary>: go1.27.4"
            word = line.rsplit(" ", 1)[-1]
            go_version = word if word.startswith("go") else None
            continue
        fields = [field for field in line.split("\t") if field]
        if len(fields) >= 3 and fields[0] == "dep":
            modules.append([fields[1], fields[2]])
        elif len(fields) >= 3 and fields[0] == "=>" and modules:
            # A replacement: the code is the replacement's.
            modules[-1] = [fields[1], fields[2]]
    return go_version, modules


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--check", action="store_true")
    options = parser.parse_args()

    lock = lock_values(options.lock)
    environment = dict(os.environ)
    cache = subprocess.run(["go", "env", "GOMODCACHE"], capture_output=True, text=True, check=True, env=environment,
                           cwd=options.source).stdout.strip()
    goroot = subprocess.run(["go", "env", "GOROOT"], capture_output=True, text=True, check=True, env=environment,
                            cwd=options.source).stdout.strip()
    go_version, modules = binary_modules(options.binary, environment)
    if not modules:
        sys.exit("error: the binary names no modules (was it built without its build information?)")

    rule = "=" * 96
    out = []
    out.append("Lumen — Xray-core and the code built into it")
    out.append("")
    out.append("Lumen.app/Contents/MacOS/LumenXray is Xray-core %s (commit %s), built unmodified from its" % (lock["XRAY_TAG"], lock["XRAY_COMMIT"]))
    out.append("source with Go %s by scripts/build-xray.sh. Lumen runs it as the relay of a profile whose proxy is a" % lock["GO_VERSION"])
    out.append("VLESS, VMess, Trojan or Shadowsocks link; it is a separate program, started by Lumen, and is not")
    out.append("linked into Lumen's own code.")
    out.append("")
    out.append("Xray-core is licensed under the Mozilla Public License, version 2.0 (below). Its source code, in the")
    out.append("form this binary was built from, is available at:")
    out.append("")
    out.append("    %s/tree/%s" % (lock["XRAY_REPOSITORY"], lock["XRAY_TAG"]))
    out.append("    %s/commit/%s" % (lock["XRAY_REPOSITORY"], lock["XRAY_COMMIT"]))
    out.append("")
    out.append("The Go modules built into it, as the binary names them (`go version -m`), each with its licence,")
    out.append("follow; then the Go standard library's (%s)." % (go_version or "go" + lock["GO_VERSION"]))
    out.append("")
    missing = []
    for module, version in modules:
        directory = module_cache_path(cache, module, version)
        if not os.path.isdir(directory):
            missing.append("%s@%s (not in the module cache: run build-xray.sh first)" % (module, version))
            continue
        files = licence_files(directory)
        if not files:
            missing.append("%s@%s (no licence file)" % (module, version))
            continue
        out.append(rule)
        out.append("%s %s" % (module, version))
        out.append(rule)
        for path in files:
            out.append("")
            out.append("--- %s ---" % os.path.basename(path))
            with open(path, encoding="utf-8", errors="replace") as handle:
                out.append(handle.read().rstrip())
        out.append("")
    # Xray-core itself is the main module, not a dependency: its licence from the source.
    out.append(rule)
    out.append("github.com/xtls/xray-core %s (the main module)" % lock["XRAY_TAG"])
    out.append(rule)
    with open(os.path.join(options.source, "LICENSE"), encoding="utf-8") as handle:
        out.append("")
        out.append(handle.read().rstrip())
    out.append("")
    out.append(rule)
    out.append("The Go standard library and runtime (%s)" % (go_version or "go" + lock["GO_VERSION"]))
    out.append(rule)
    with open(os.path.join(goroot, "LICENSE"), encoding="utf-8") as handle:
        out.append("")
        out.append(handle.read().rstrip())
    patents = os.path.join(goroot, "PATENTS")
    if os.path.isfile(patents):
        with open(patents, encoding="utf-8") as handle:
            out.append("")
            out.append("--- PATENTS ---")
            out.append(handle.read().rstrip())
    out.append("")
    if missing:
        sys.exit("error: no licence for: " + "; ".join(missing))
    text = "\n".join(out)
    if options.check:
        with open(options.out, encoding="utf-8") as handle:
            if handle.read() != text:
                sys.exit("error: %s is not what this pin of Xray needs: run scripts/build-xray.sh --record" % options.out)
        print("%s matches Xray %s: %d modules" % (options.out, lock["XRAY_TAG"], len(modules)))
        return
    os.makedirs(os.path.dirname(options.out), exist_ok=True)
    with open(options.out, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("Wrote %s: Xray %s, %d modules" % (options.out, lock["XRAY_TAG"], len(modules)))


if __name__ == "__main__":
    main()
