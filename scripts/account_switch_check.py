#!/usr/bin/env python3
"""A profile's data while this Mac signs out of one account, into another, and back (the owner,
3 November: a person's history, cookies and saved logins gone from every profile after signing out,
into other accounts and back). Profiles are this Mac's, not an account's (CONTRACT §2, §6.3, §12):
nothing of them may change with the account.

    python3 scripts/account_switch_check.py --app build/unsandboxed/Lumen.app --out build/account-switch

Runs `Lumen --selftest-account-switch` (AccountSwitchScenario.swift) in a vault folder of its own,
with the account server played inside the app: two profiles, each with 25 visits, 3 saved logins,
4 bookmarks and 5 cookies; signed in as a first account, the profiles launched and stopped, signed
out, signed in as a second account, the profiles launched and stopped, the vault locked and opened,
signed out, signed in as the first again, the profiles launched and stopped. At every step it writes
down each profile's files (path, size, SHA-256) and what they hold.

Prints, and writes to <out>/report.md: a table of the counts at every step, and the files that came,
went or changed from one step to the next. FAIL when any count at any step is not what was made,
when a profile's settings change, or when a file holding the data (history.bin, passwords.bin,
bookmarks.bin, cookies.bin, the sealed archives once made) is gone. Exit 1 on a FAIL, 2 when the
scenario did not run to its end.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

EXPECTED = {"history": 25, "logins": 3, "bookmarks": 4, "cookies": 5}
KEPT = ("history.bin", "passwords.bin", "bookmarks.bin", "cookies.bin")
# Made at the first stop, and to stay from then on.
SEALED = ("webdata.pbsa", "safarihome.pbsa")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    arguments = parser.parse_args()
    out = os.path.abspath(arguments.out)
    os.makedirs(out, exist_ok=True)
    executable = os.path.join(arguments.app, "Contents", "MacOS", "Lumen")
    vault = tempfile.mkdtemp(prefix="pb-account-switch-")
    environment = dict(os.environ, PB_SELFTEST_ACCOUNT_SWITCH="1", PRIVACYBROWSER_VAULT_DIR=vault, PRIVACYBROWSER_LANG="en")
    try:
        run = subprocess.run([executable, "--selftest-account-switch"], env=environment, capture_output=True, text=True,
                             errors="replace", timeout=960)
        output, status = run.stdout, run.returncode
        with open(os.path.join(out, "stderr.txt"), "w") as handle:
            handle.write(run.stderr)
    except subprocess.TimeoutExpired as error:
        output, status = (error.stdout or b"").decode("utf-8", "replace") if isinstance(error.stdout, bytes) else (error.stdout or ""), -1
    with open(os.path.join(out, "scenario.txt"), "w") as handle:
        handle.write(output)

    steps = []  # [(step, {profile: counts}, {profile: {path: (size, hash)}})]
    for line in output.splitlines():
        if not line.startswith("ACCOUNT-SWITCH"):
            continue
        if line.startswith("ACCOUNT-SWITCH STEP "):
            steps.append((line[len("ACCOUNT-SWITCH STEP "):], {}, {}))
        elif line.startswith("ACCOUNT-SWITCH COUNT ") and steps:
            match = re.match(r"ACCOUNT-SWITCH COUNT (Switch \w+) (.*)", line)
            if match:
                steps[-1][1][match.group(1)] = dict(re.findall(r"([\w-]+)=(\S+(?: bytes)?)", match.group(2)))
                if "unreadable" in match.group(2):
                    steps[-1][1][match.group(1)]["unreadable"] = match.group(2)
        elif line.startswith("ACCOUNT-SWITCH FILE ") and steps:
            parts = line.split(" ")
            if len(parts) >= 7:
                profile = parts[2] + " " + parts[3]
                path, size, digest = parts[4], parts[5], parts[6]
                steps[-1][2].setdefault(profile, {})[path] = (size, digest)
        else:
            print(line, flush=True)

    report, failures = [], []
    profiles = sorted({name for _, counts, _ in steps for name in counts})
    report.append("| step | " + " | ".join(f"{p}: history / logins / bookmarks / cookies / settings / WebKit store outside" for p in profiles) + " |")
    report.append("|---|" + "---|" * len(profiles))
    first_settings = {}
    for step, counts, _ in steps:
        cells = []
        for profile in profiles:
            c = counts.get(profile, {})
            cells.append(" / ".join(str(c.get(key, "?")) for key in ("history", "logins", "bookmarks", "cookies", "settings"))
                         + " / " + str(c.get("webkit-store-outside-the-vault", "?")))
            for key, wanted in EXPECTED.items():
                if c.get(key) != str(wanted):
                    failures.append(f"step «{step}», {profile}: {key} {c.get(key, 'not read')}, made {wanted}")
            if "settings" in c:
                first_settings.setdefault(profile, (step, c["settings"]))
                if c["settings"] != first_settings[profile][1]:
                    failures.append(f"step «{step}», {profile}: its settings changed (hash {c['settings']}, "
                                    f"{first_settings[profile][1]} at «{first_settings[profile][0]}»)")
            if "unreadable" in c:
                failures.append(f"step «{step}», {profile}: {c['unreadable']}")
        report.append(f"| {step} | " + " | ".join(cells) + " |")

    report.append("")
    report.append("Files, step by step (what came, went or changed since the step before):")
    previous = {}
    sealed_seen = {}
    for step, _, files in steps:
        report.append(f"- {step}:")
        for profile in profiles:
            now = files.get(profile, {})
            before = previous.get(profile)
            if before is None:
                listed = ", ".join(f"{path} {size} B {digest}" for path, (size, digest) in sorted(now.items()))
                report.append(f"  - {profile}: {len(now)} files: {listed}")
            else:
                came = sorted(set(now) - set(before))
                went = sorted(set(before) - set(now))
                changed = sorted(p for p in set(now) & set(before) if now[p] != before[p])
                said = []
                if came: said.append("came " + ", ".join(f"{p} {now[p][0]} B" for p in came))
                if went: said.append("WENT " + ", ".join(f"{p} ({before[p][0]} B)" for p in went))
                if changed: said.append("changed " + ", ".join(f"{p} {before[p][0]}→{now[p][0]} B" for p in changed))
                report.append(f"  - {profile}: " + ("; ".join(said) if said else "the same files, byte for byte"))
            for name in KEPT:
                if name not in now:
                    failures.append(f"step «{step}», {profile}: {name} is not there")
            for name in SEALED:
                if name in now:
                    sealed_seen.setdefault(profile, set()).add(name)
                elif name in sealed_seen.get(profile, set()):
                    failures.append(f"step «{step}», {profile}: {name}, there before, is gone")
            previous[profile] = now

    finished = "ACCOUNT-SWITCH done" in output
    text = "\n".join(report)
    print(text, flush=True)
    with open(os.path.join(out, "report.md"), "w") as handle:
        handle.write(text + "\n\n" + ("\n".join("FAIL " + f for f in failures) or "every count as made at every step") + "\n")
    for failure in failures:
        print(f"ACCOUNT-SWITCH-CHECK FAIL {failure}", flush=True)
    if not finished:
        print(f"ACCOUNT-SWITCH-CHECK DID NOT FINISH (exit {status}): {len(steps)} step(s) measured", flush=True)
        return 2
    if failures:
        print(f"ACCOUNT-SWITCH-CHECK FAILED: {len(failures)} finding(s) over {len(steps)} steps", flush=True)
        return 1
    print(f"ACCOUNT-SWITCH-CHECK PASSED: every profile's history, logins, bookmarks, cookies and settings as made, "
          f"at each of {len(steps)} steps", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
