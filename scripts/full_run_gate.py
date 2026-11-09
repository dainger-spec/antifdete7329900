#!/usr/bin/env python3
"""Is there a full CI run that passed on this very commit? release.sh asks before it builds anything.

    python3 scripts/full_run_gate.py --sha <commit> [--repo owner/name] [--runs-json file]

The owner, 3 November: the checks are split in two — the fast pipeline (.github/workflows/ci.yml)
on every push, the full one (.github/workflows/full.yml: every check, measurement, inventory,
snapshot, macOS 27) once a day and on request — and a release on a commit the full pipeline has not
passed is not allowed. This asks GitHub for the full workflow's runs of the commit and answers:

    exit 0  a run of full.yml on exactly this commit completed with success (named, with its address)
    exit 1  none did: never run, still running, or failed — each said, with how to start one
    exit 2  GitHub could not be asked (no network, an answer that is not GitHub's): not a yes

A run on another commit, however close, is not this commit's: the commit is what is released.
`--runs-json` reads a saved answer of the API instead of asking (the tests, scripts/test_full_run_gate.sh).
GITHUB_TOKEN, when set, is sent (the API's limit for a caller without one is 60 an hour).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

WORKFLOW = "full.yml"


def repo_from_origin():
    try:
        url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    match = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$", url)
    return f"{match.group(1)}/{match.group(2)}" if match else None


def fetch_runs(repo, sha):
    url = f"https://api.github.com/repos/{repo}/actions/workflows/{WORKFLOW}/runs?head_sha={sha}&per_page=50"
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "lumen-release-gate"})
    if os.environ.get("GITHUB_TOKEN"):
        request.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")
    with urllib.request.urlopen(request, timeout=30) as answer:
        return json.load(answer)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sha", required=True, help="the commit to be released (a full SHA)")
    parser.add_argument("--repo", help="owner/name; default: origin's")
    parser.add_argument("--runs-json", help="a saved answer of the API instead of asking it")
    arguments = parser.parse_args()
    sha = arguments.sha.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        print(f"full run: '{arguments.sha}' is not a full commit SHA")
        return 2
    short = sha[:12]
    start = (f"start one on this commit: git tag full/{short} {sha} && git push origin full/{short} "
             f"(or Actions › CI — full › Run workflow, on this commit's branch)")
    repo = arguments.repo or repo_from_origin()
    try:
        if arguments.runs_json:
            with open(arguments.runs_json) as handle:
                answer = json.load(handle)
        else:
            if not repo:
                print("full run: the repository on GitHub is not known (origin is not a GitHub address): not a yes")
                return 2
            answer = fetch_runs(repo, sha)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            print(f"full run: GitHub knows no workflow {WORKFLOW} in {repo} (not pushed yet): none on {short} — {start}")
            return 1
        print(f"full run: GitHub could not be asked ({error}): not a yes — a release waits for a passed full run")
        return 2
    except (OSError, urllib.error.URLError, ValueError) as error:
        print(f"full run: GitHub could not be asked ({error}): not a yes — a release waits for a passed full run")
        return 2
    runs = answer.get("workflow_runs") if isinstance(answer, dict) else None
    if not isinstance(runs, list):
        print("full run: GitHub's answer has no list of runs: not a yes")
        return 2
    mine = [run for run in runs if str(run.get("head_sha", "")).lower() == sha
            and str(run.get("path", "")).split("@")[0].endswith(f".github/workflows/{WORKFLOW}")]
    passed = [run for run in mine if run.get("status") == "completed" and run.get("conclusion") == "success"]
    if passed:
        run = max(passed, key=lambda r: r.get("run_number", 0))
        print(f"full run: #{run.get('run_number')} passed on {short} ({run.get('html_url', 'no address')})")
        return 0
    running = [run for run in mine if run.get("status") != "completed"]
    if running:
        run = max(running, key=lambda r: r.get("run_number", 0))
        print(f"full run: #{run.get('run_number')} on {short} is {run.get('status')}, not passed yet ({run.get('html_url', '')}): "
              "a release waits for it")
        return 1
    if mine:
        run = max(mine, key=lambda r: r.get("run_number", 0))
        print(f"full run: #{run.get('run_number')} on {short} ended {run.get('conclusion')} ({run.get('html_url', '')}): "
              f"nothing released; fix it, then {start}")
        return 1
    print(f"full run: none on {short} — {start}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
