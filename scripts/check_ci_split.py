#!/usr/bin/env python3
"""The two CI pipelines stay what the owner set them to be (3 November).

    python3 scripts/check_ci_split.py [workflows folder]      (default: .github/workflows)
    python3 scripts/check_ci_split.py --self-check             (the check against planted workflows)

- ci.yml, the fast pipeline, runs on a push to a branch and on nothing else: one run per commit
  (a push and a pull_request of the same head ran every commit twice — 674/675, 678/679, 682/683).
- It holds only steps whose failure means "do not release": no step or job that may fail without
  failing it (continue-on-error), and none named as a measurement, a report or an inventory — those
  belong to the full pipeline.
- full.yml, the full pipeline, runs once a day, on request and on a pushed tag full/…, never on a
  branch's push or a pull request; and it runs every script the fast one runs (it is a superset:
  release.sh asks for a passed full run, so nothing checked fast may be missing from it).

`--self-check` runs the same rules over planted workflows — a second trigger, a step that cannot
fail, a measurement, a script the full pipeline lacks, a full pipeline on push — and fails unless
each is found and a correct pair passes: a check that cannot fail checks nothing.
"""
import os
import re
import sys
import tempfile

MEASUREMENT = re.compile(r"\(a measurement|\(reported\)|never fails|\(an inventory|report, never fails|\(a measure", re.I)
SCRIPT = re.compile(r"scripts/[A-Za-z0-9_./-]+\.(?:py|sh|mjs)")


def triggers(text):
    """The events under `on:`, each with the raw lines of its block."""
    lines = text.split("\n")
    found, inside, current = {}, False, None
    for line in lines:
        if re.match(r"^on:\s*$", line):
            inside = True
            continue
        if inside:
            if line and not line.startswith(" ") and not line.startswith("#"):
                break
            match = re.match(r"^  ([a-z_]+):", line)
            if match:
                current = match.group(1)
                found[current] = []
            elif current and line.strip() and not line.strip().startswith("#"):
                found[current].append(line.strip())
    return found


def step_names(text):
    return [m.group(1).strip() for m in re.finditer(r"^\s+- name:\s*(.+)$", text, re.M)]


def scripts_run(text):
    found = set()
    for line in text.split("\n"):
        code = line.split("#", 1)[0] if line.lstrip().startswith("#") else line
        if line.lstrip().startswith("#"):
            continue
        found.update(SCRIPT.findall(code))
    return found


def check(folder):
    problems = []
    try:
        fast = open(os.path.join(folder, "ci.yml")).read()
        full = open(os.path.join(folder, "full.yml")).read()
    except OSError as error:
        return [f"a pipeline is missing: {error}"]
    fast_on, full_on = triggers(fast), triggers(full)
    if set(fast_on) != {"push"}:
        problems.append(f"ci.yml (fast) runs on {sorted(fast_on)}: only on push, one run per commit")
    elif not any(l.startswith("branches") for l in fast_on["push"]) or any(l.startswith("tags") for l in fast_on["push"]):
        problems.append("ci.yml (fast) must run on a push to a branch (branches:), not on a tag")
    for event in ("pull_request", "pull_request_target"):
        if event in full_on:
            problems.append(f"full.yml runs on {event}")
    if "push" in full_on and any(l.startswith("branches") for l in full_on["push"]):
        problems.append("full.yml runs on a branch's push: it runs daily, on request and on a tag full/… only")
    for event in ("schedule", "workflow_dispatch"):
        if event not in full_on:
            problems.append(f"full.yml does not run on {event}")
    if "push" not in full_on or not any("full/" in l for l in full_on.get("push", [])):
        problems.append("full.yml does not run on a pushed tag full/… (release.sh's way to start one on a commit)")
    for number, line in enumerate(fast.split("\n"), 1):
        if re.match(r"^\s+continue-on-error:\s*(true|\$\{\{)", line):
            problems.append(f"ci.yml:{number}: continue-on-error — a step or job that cannot fail is a measurement, its place is full.yml")
    for name in step_names(fast):
        if MEASUREMENT.search(name):
            problems.append(f"ci.yml: the step «{name}» is a measurement, a report or an inventory — its place is full.yml")
    missing = sorted(scripts_run(fast) - scripts_run(full))
    for script in missing:
        problems.append(f"ci.yml runs {script}, full.yml does not: the full pipeline must hold every check of the fast one")
    return problems


GOOD_FAST = """name: CI
on:
  push:
    branches: ['**']
jobs:
  a:
    steps:
      - name: Deletion paths
        run: python3 scripts/check_deletion_paths.py
"""
GOOD_FULL = """name: CI — full
on:
  workflow_dispatch:
  schedule:
    - cron: '17 2 * * *'
  push:
    tags: ['full/**']
jobs:
  a:
    steps:
      - name: Deletion paths
        run: python3 scripts/check_deletion_paths.py
      - name: Safari's paths (a measurement)
        continue-on-error: true
        run: python3 scripts/paths.py
"""
BAD = {
    "a second trigger": (GOOD_FAST.replace("    branches: ['**']\n", "    branches: ['**']\n  pull_request:\n"), GOOD_FULL),
    "a step that cannot fail": (GOOD_FAST + "        continue-on-error: true\n", GOOD_FULL),
    "a measurement": (GOOD_FAST + "      - name: Safari's paths (a measurement)\n        run: echo\n", GOOD_FULL),
    "a script the full pipeline lacks": (GOOD_FAST + "      - name: Leak check\n        run: python3 scripts/leak_check.py\n", GOOD_FULL),
    "a full pipeline on push": (GOOD_FAST, GOOD_FULL.replace("    tags: ['full/**']", "    branches: ['**']")),
    "a full pipeline without a schedule": (GOOD_FAST, GOOD_FULL.replace("  schedule:\n    - cron: '17 2 * * *'\n", "")),
}


def self_check():
    with tempfile.TemporaryDirectory() as root:
        def write(fast, full):
            open(os.path.join(root, "ci.yml"), "w").write(fast)
            open(os.path.join(root, "full.yml"), "w").write(full)
        write(GOOD_FAST, GOOD_FULL)
        good = check(root)
        if good:
            print(f"ci split self-check: FAILED — a correct pair was refused: {good}")
            return 1
        for what, (fast, full) in BAD.items():
            write(fast, full)
            if not check(root):
                print(f"ci split self-check: FAILED — {what} was not found")
                return 1
    print(f"ci split self-check: each of {len(BAD)} planted faults found, the correct pair passed")
    return 0


def main():
    if "--self-check" in sys.argv[1:]:
        return self_check()
    folder = next((a for a in sys.argv[1:] if not a.startswith("-")), ".github/workflows")
    problems = check(folder)
    for problem in problems:
        print(f"ci split: {problem}")
    if problems:
        print(f"ci split: {len(problems)} problem(s)")
        return 1
    print("ci split: ci.yml runs once per commit and only checks that fail it; full.yml runs daily, on request and on "
          "a tag full/…, and holds every check of the fast one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
