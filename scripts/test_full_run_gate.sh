#!/bin/bash
# scripts/full_run_gate.py against saved answers of GitHub's API: only a passed run of full.yml on
# exactly the commit says yes; everything else — none, still running, failed, another commit,
# another workflow, an answer that is not GitHub's — says no. A gate that cannot say no checks nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=89abcdef0123456789abcdef0123456789abcdef
status=0

run() { # <name> <head_sha> <path> <status> <conclusion> <number>
  printf '{"head_sha": "%s", "path": ".github/workflows/%s", "status": "%s", "conclusion": %s, "run_number": %s, "html_url": "https://example.invalid/%s"}' \
    "$2" "$3" "$4" "$5" "$6" "$1"
}
case_() { # <expected exit> <what> <json>
  printf '%s' "$3" > "$WORK/runs.json"
  out="$(python3 -I "$HERE/full_run_gate.py" --sha "$SHA" --repo o/r --runs-json "$WORK/runs.json" 2>&1)"
  code=$?
  if [[ "$code" == "$1" ]]; then echo "ok    ($code) $2: $out"; else echo "WRONG (exit $code, wanted $1) $2: $out"; status=1; fi
}

case_ 0 "a passed full run on this commit" "{\"workflow_runs\": [$(run a $SHA full.yml completed '"success"' 7)]}"
case_ 0 "a failed attempt, then a passed one, on this commit" \
  "{\"workflow_runs\": [$(run a $SHA full.yml completed '"failure"' 7), $(run b $SHA full.yml completed '"success"' 8)]}"
case_ 1 "no run at all" '{"workflow_runs": []}'
case_ 1 "the full run failed on this commit" "{\"workflow_runs\": [$(run a $SHA full.yml completed '"failure"' 7)]}"
case_ 1 "the full run is still running" "{\"workflow_runs\": [$(run a $SHA full.yml in_progress null 7)]}"
case_ 1 "cancelled" "{\"workflow_runs\": [$(run a $SHA full.yml completed '"cancelled"' 7)]}"
case_ 1 "passed, but on another commit" "{\"workflow_runs\": [$(run a $OTHER full.yml completed '"success"' 7)]}"
case_ 1 "passed, but the fast pipeline, not the full one" "{\"workflow_runs\": [$(run a $SHA ci.yml completed '"success"' 7)]}"
case_ 2 "an answer that is not GitHub's" '{"message": "API rate limit exceeded"}'
case_ 2 "not JSON at all" 'Service Unavailable'
out="$(python3 -I "$HERE/full_run_gate.py" --sha abc --repo o/r --runs-json /dev/null 2>&1)"; code=$?
if [[ "$code" == 2 ]]; then echo "ok    (2) a short SHA is refused: $out"; else echo "WRONG (exit $code) a short SHA: $out"; status=1; fi

(( status == 0 )) && echo "full run gate: every case answered as it must" || echo "full run gate: FAILED"
exit $status
