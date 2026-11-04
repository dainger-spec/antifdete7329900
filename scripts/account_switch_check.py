#!/usr/bin/env python3
"""A profile's data while this Mac signs out of one account, into others, and back (the owner,
3 November: a person's history, cookies and saved logins gone from every profile after signing out,
into other accounts and back). Profiles are this Mac's, not an account's (CONTRACT §2, §6.3, §12):
nothing of them may change with the account.

    python3 scripts/account_switch_check.py --app build/unsandboxed/Lumen.app --out build/account-switch

Runs `Lumen --selftest-account-switch` (AccountSwitchScenario.swift) once per phase, in a vault
folder of its own, the app quitting between phases as a person's does; the account server is played
inside the app. Two profiles, each with 25 visits, 3 saved logins and 4 bookmarks; a site opened in
each that keeps a cookie, a localStorage item and an IndexedDB record and says what it found of
them. Signed in as a first account, quit, signed out, signed in as a second, then as a third without
a license (export only), signed out, signed in as the first again. At every measured step it writes
down each profile's files (path, size, SHA-256), what they hold, and what its sealed archives hold.

Prints, and writes to <out>/report.md: a table of the counts at every step, what the site found at
every visit, and the files that came, went or changed from one step to the next. FAIL when:
- the site, at any visit, finds its cookie, localStorage item or IndexedDB record other than as many
  visits as were made (the data is gone, or older than its last visit), or a profile did not start or
  the site did not report;
- a profile's saved logins or bookmarks are not as made, its history has fewer visits than at the
  step before (or than made), or lacks a visit of the site made in it, its synced cookies fewer than at the step before, its settings changed;
- a file holding the data (history.bin, passwords.bin, bookmarks.bin, and cookies.bin and the
  sealed archives once made) is gone, or the site's data, once in WebKit's sealed store, is no longer there;
- the list of profiles changed;
- a profile started while the account allowed export only.
Exit 1 on a FAIL, 2 when a phase did not run to its end.

    --control   the scenario removes every profile's webdata.pbsa, cookies.bin, history.bin and
                passwords.bin at the first sign-out (the loss the person saw): exit 0 when the check
                fails on it, as it must, 1 when it passes.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

LOGINS, BOOKMARKS, VISITS = 3, 4, 25
# Made with the profile's data, and to stay.
KEPT = ("history.bin", "passwords.bin", "bookmarks.bin")
# Made at the first stop (cookies.bin when the store first holds a cookie), and to stay from then on.
SEALED = ("cookies.bin", "webdata.pbsa", "safarihome.pbsa")
PHASE_TIMEOUT = 300


def run_phases(executable, out, vault, state, control):
    """Runs every phase in turn; returns (output of all, the phase that did not finish or None)."""
    outputs = []
    phase = 1
    while True:
        environment = dict(os.environ, PB_SELFTEST_ACCOUNT_SWITCH="1", PRIVACYBROWSER_VAULT_DIR=vault,
                           PRIVACYBROWSER_LANG="en", PB_SWITCH_STATE=state, PB_SWITCH_PHASE=str(phase),
                           PB_SWITCH_CONTROL="1" if control else "0")
        print(f"== phase {phase}", flush=True)
        try:
            run = subprocess.run([executable, "--selftest-account-switch"], env=environment, capture_output=True,
                                 text=True, errors="replace", timeout=PHASE_TIMEOUT)
            output, status, errors = run.stdout, run.returncode, run.stderr
        except subprocess.TimeoutExpired as error:
            output = error.stdout.decode("utf-8", "replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
            errors = error.stderr.decode("utf-8", "replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
            status = "timeout"
        outputs.append(output)
        with open(os.path.join(out, f"stderr-phase{phase}.txt"), "w") as handle:
            handle.write(errors)
        for line in output.splitlines():
            if line.startswith("ACCOUNT-SWITCH") and not line.startswith(("ACCOUNT-SWITCH FILE ", "ACCOUNT-SWITCH COUNT ")):
                print("  " + line, flush=True)
        if f"ACCOUNT-SWITCH phase {phase} done" not in output:
            print(f"  phase {phase} did not finish (exit {status})", flush=True)
            return "\n".join(outputs), phase
        if "ACCOUNT-SWITCH last phase done" in output:
            return "\n".join(outputs), None
        phase += 1
        if phase > 30:
            return "\n".join(outputs), phase


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--control", action="store_true",
                        help="the loss the person saw, made by the scenario at the first sign-out: the check must fail")
    arguments = parser.parse_args()
    out = os.path.abspath(arguments.out)
    os.makedirs(out, exist_ok=True)
    executable = os.path.join(arguments.app, "Contents", "MacOS", "Lumen")
    vault = tempfile.mkdtemp(prefix="pb-account-switch-")
    # The scenario's state (the played server's signing key among it) stays out of what is uploaded.
    state_dir = tempfile.mkdtemp(prefix="pb-account-switch-state-")
    try:
        output, unfinished = run_phases(executable, out, vault, os.path.join(state_dir, "state.json"), arguments.control)
    finally:
        shutil.rmtree(state_dir, ignore_errors=True)
    with open(os.path.join(out, "scenario.txt"), "w") as handle:
        handle.write(output)

    steps = []  # [(step, {profile: counts}, {profile: {path: (size, hash)}}, listed)]
    pages = []  # [(profile, step, expected, fields or problem)]
    started_while_export_only = []
    for line in output.splitlines():
        if line.startswith("ACCOUNT-SWITCH STEP "):
            steps.append((line[len("ACCOUNT-SWITCH STEP "):], {}, {}, None))
        elif line.startswith("ACCOUNT-SWITCH LISTED ") and steps:
            step, counts, files, _ = steps[-1]
            steps[-1] = (step, counts, files, line[len("ACCOUNT-SWITCH LISTED "):])
        elif line.startswith("ACCOUNT-SWITCH COUNT ") and steps:
            parts = line.split(" ", 3)
            if len(parts) == 4:
                steps[-1][1][parts[2]] = dict(re.findall(r"([\w-]+)=(\S+)", parts[3]))
        elif line.startswith("ACCOUNT-SWITCH FILE ") and steps:
            parts = line.split(" ")
            if len(parts) >= 6:
                steps[-1][2].setdefault(parts[2], {})[parts[3]] = (parts[4], parts[5])
        elif line.startswith("ACCOUNT-SWITCH PAGE "):
            match = re.match(r"ACCOUNT-SWITCH PAGE (.+?) step=(\d+) expected=(\d+) (.*)", line)
            if match:
                fields = dict(re.findall(r"([\w-]+)=(\S+)", match.group(4)))
                pages.append((match.group(1), int(match.group(2)), int(match.group(3)), fields or match.group(4)))
        elif line.startswith("ACCOUNT-SWITCH asked to start") and "STARTED" in line:
            started_while_export_only.append(line)

    report, failures = [], []
    profiles = sorted({name for _, counts, _, _ in steps for name in counts})
    columns = ("history", "history-site", "visits-made", "logins", "bookmarks", "cookies", "cookies-site", "settings", "webdata-bytes", "webdata-cookies",
               "webdata-site", "safarihome-bytes", "safarihome-site", "webkit-store-outside-the-vault")
    report.append("| step | profile | " + " | ".join(columns) + " |")
    report.append("|---|---|" + "---|" * len(columns))
    first_settings, before, site_sealed, first_listed = {}, {}, {}, None
    for step, counts, _, listed in steps:
        if listed is not None:
            first_listed = first_listed or listed
            if listed != first_listed:
                failures.append(f"step «{step}»: the profiles listed are {listed}, were {first_listed}")
        for profile in profiles:
            c = counts.get(profile, {})
            report.append(f"| {step} | {profile} | " + " | ".join(str(c.get(key, "?")) for key in columns) + " |")
            if "unreadable" in c:
                failures.append(f"step «{step}», {profile}: unreadable {c['unreadable']}")
                continue
            for key, wanted in (("logins", LOGINS), ("bookmarks", BOOKMARKS)):
                if c.get(key) != str(wanted):
                    failures.append(f"step «{step}», {profile}: {key} {c.get(key, 'not read')}, made {wanted}")
            for key, floor in (("history", VISITS), ("cookies", 0)):
                value = int(c[key]) if c.get(key, "").isdigit() else None
                earlier = before.get((profile, key), floor)
                if value is None:
                    failures.append(f"step «{step}», {profile}: {key} not read")
                elif value < earlier:
                    failures.append(f"step «{step}», {profile}: {key} {value}, {earlier} at the step before")
                else:
                    before[(profile, key)] = value
            # Every visit of the site is in the profile's history (one address per visit).
            made = int(c.get("visits-made", "0")) if c.get("visits-made", "0").isdigit() else 0
            site_history = int(c["history-site"]) if c.get("history-site", "").isdigit() else None
            if site_history is None:
                failures.append(f"step «{step}», {profile}: the site's visits in its history not read")
            elif site_history < made:
                failures.append(f"step «{step}», {profile}: {site_history} of the site's {made} visits are in its history")
            if "settings" in c:
                first_settings.setdefault(profile, (step, c["settings"]))
                if c["settings"] != first_settings[profile][1]:
                    failures.append(f"step «{step}», {profile}: its settings changed (hash {c['settings']}, "
                                    f"{first_settings[profile][1]} at «{first_settings[profile][0]}»)")
            if c.get("webdata-site", "nowhere") not in ("nowhere", "?"):
                site_sealed.setdefault(profile, step)
            elif profile in site_sealed:
                failures.append(f"step «{step}», {profile}: the site's data is no longer in WebKit's sealed store "
                                f"(there since «{site_sealed[profile]}»; webdata {c.get('webdata-files', '?')} files, "
                                f"{c.get('webdata-bytes', '?')} bytes)")

    report.append("")
    report.append("What the site found at each visit (cookie / localStorage / IndexedDB; as many as visits made before):")
    for profile, step, expected, fields in pages:
        if not isinstance(fields, dict):
            report.append(f"- phase {step}, {profile}: {fields}")
            failures.append(f"phase {step}, {profile}: the site did not report ({fields})")
            continue
        found = [fields.get(key, "?") for key in ("cookie", "local", "idb")]
        report.append(f"- phase {step}, {profile}: expected {expected}, found {' / '.join(found)} "
                      f"(wrote {fields.get('next', '?')}, IndexedDB written: {fields.get('idbWritten', '?')})")
        for key, value in zip(("cookie", "localStorage", "IndexedDB"), found):
            if value != str(expected):
                failures.append(f"phase {step}, {profile}: the site's {key} says {value} visits, {expected} were made")
    if not pages:
        failures.append("no visit reported: the site was never opened")
    for line in started_while_export_only:
        failures.append(f"export only, yet: {line}")

    report.append("")
    report.append("Files, step by step (what came, went or changed since the step before):")
    previous, sealed_seen = {}, {}
    for step, _, files, _ in steps:
        report.append(f"- {step}:")
        for profile in profiles:
            now = files.get(profile, {})
            earlier = previous.get(profile)
            if earlier is None:
                listed = ", ".join(f"{path} {size} B {digest}" for path, (size, digest) in sorted(now.items()))
                report.append(f"  - {profile}: {len(now)} files: {listed}")
            else:
                came = sorted(set(now) - set(earlier))
                went = sorted(set(earlier) - set(now))
                changed = sorted(p for p in set(now) & set(earlier) if now[p] != earlier[p])
                said = []
                if came: said.append("came " + ", ".join(f"{p} {now[p][0]} B" for p in came))
                if went: said.append("WENT " + ", ".join(f"{p} ({earlier[p][0]} B)" for p in went))
                if changed: said.append("changed " + ", ".join(f"{p} {earlier[p][0]}→{now[p][0]} B" if earlier[p][0] != now[p][0]
                                                       else f"{p} {now[p][0]} B, its hash {earlier[p][1]}→{now[p][1]}" for p in changed))
                report.append(f"  - {profile}: " + ("; ".join(said) if said else "the same files, byte for byte"))
            names = {path.split("/")[-1] for path in now}
            for name in KEPT:
                if name not in names:
                    failures.append(f"step «{step}», {profile}: {name} is not there")
            for name in SEALED:
                if name in names:
                    sealed_seen.setdefault(profile, set()).add(name)
                elif name in sealed_seen.get(profile, set()):
                    failures.append(f"step «{step}», {profile}: {name}, there before, is gone")
            previous[profile] = now

    text = "\n".join(report)
    print(text, flush=True)
    with open(os.path.join(out, "report.md"), "w") as handle:
        handle.write(text + "\n\n" + ("\n".join("FAIL " + f for f in failures) or "every count as made at every step") + "\n")
    for failure in failures:
        print(f"ACCOUNT-SWITCH-CHECK FAIL {failure}", flush=True)
    if unfinished is not None:
        print(f"ACCOUNT-SWITCH-CHECK DID NOT FINISH: phase {unfinished}; {len(steps)} step(s) measured", flush=True)
        return 2
    if arguments.control:
        if failures:
            print(f"ACCOUNT-SWITCH-CHECK the control fails the check, as it must ({len(failures)} findings)", flush=True)
            return 0
        print("ACCOUNT-SWITCH-CHECK the control PASSED the check: a check that cannot fail shows nothing", flush=True)
        return 1
    if failures:
        print(f"ACCOUNT-SWITCH-CHECK FAILED: {len(failures)} finding(s) over {len(steps)} steps and {len(pages)} visits", flush=True)
        return 1
    print(f"ACCOUNT-SWITCH-CHECK PASSED: every profile's site data, history, logins, bookmarks, cookies and settings "
          f"kept, at each of {len(steps)} steps and {len(pages)} visits", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
