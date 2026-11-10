#!/bin/bash
# scripts/automation_plan_gate.py against vectors made up for the purpose: only a set that shows the
# decision — the trial, Professional and Team each signed with automation, Personal without, an
# export-only document there — says yes; the server's vectors as they are before it signs the field,
# and every departure from the decision, say no. A gate that cannot say no checks nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0

# <file> <case>… — a case is name:plan:status:features, features "-" for no field, "" for an empty
# list, names joined with "+", "!text" for a value that is not a list; "bad:" before the name makes
# a case the server says does not check (never counted).
vectors() {
  python3 -I - "$@" <<'PY'
import base64, json, sys
cases = []
for spec in sys.argv[2:]:
    verify = "ok"
    if spec.startswith("bad:"):
        verify, spec = "bad_signature", spec[4:]
    name, plan, status, features = spec.split(":")
    payload = {"kind": "lumen.entitlement", "version": 1, "plan": plan, "status": status}
    if features.startswith("!"):
        payload["features"] = features[1:]
    elif features != "-":
        payload["features"] = [f for f in features.split("+") if f]
    document = {"format": 1, "keyID": "made-up", "signature": "bWFkZS11cA==",
                "payload": base64.b64encode(json.dumps(payload).encode()).decode()}
    cases.append({"name": name, "document": json.dumps(document), "deviceID": "d", "machineID": "m", "verify": verify})
json.dump({"comment": "made up", "trustedKeys": {}, "cases": cases}, open(sys.argv[1], "w"))
PY
}
case_() { # <expected exit> <what> <case>…
  local expected="$1" what="$2" out code
  shift 2
  vectors "$WORK/vectors.json" "$@"
  out="$(python3 -I "$HERE/automation_plan_gate.py" --vectors "$WORK/vectors.json" 2>&1)"
  code=$?
  if [[ "$code" == "$expected" ]]; then echo "ok    ($code) $what: $out"; else echo "WRONG (exit $code, wanted $expected) $what: $out"; status=1; fi
}

ENDED="ended:personal:export_only:-"
case_ 0 "as decided: the trial, Professional and Team with automation, Personal without" \
  t:trial:active:automation p:pro:active:automation m:team:active:automation s:personal:active:- "$ENDED"
case_ 0 "as decided, other names beside automation and an empty list for Personal" \
  t:trial:active:automation+teleport p:pro:active:automation m:team:active:automation s:personal:active: e:pro:export_only:automation
case_ 1 "the server's vectors before the field: no features anywhere" \
  valid:pro:active:- "$ENDED" over:pro:active:-
case_ 1 "Professional without automation" \
  t:trial:active:automation p:pro:active:- m:team:active:automation s:personal:active:- "$ENDED"
case_ 1 "one Professional document of two without it" \
  t:trial:active:automation p:pro:active:automation q:pro:active: m:team:active:automation s:personal:active:- "$ENDED"
case_ 1 "the trial without automation" \
  t:trial:active:teleport p:pro:active:automation m:team:active:automation s:personal:active:- "$ENDED"
case_ 1 "no Team document" \
  t:trial:active:automation p:pro:active:automation s:personal:active:- "$ENDED"
case_ 1 "Personal signed with automation" \
  t:trial:active:automation p:pro:active:automation m:team:active:automation s:personal:active:automation "$ENDED"
case_ 1 "no active Personal document" \
  t:trial:active:automation p:pro:active:automation m:team:active:automation "$ENDED"
case_ 1 "no export-only document" \
  t:trial:active:automation p:pro:active:automation m:team:active:automation s:personal:active:-
case_ 1 "features that is not a list of names (the app reads none)" \
  t:trial:active:automation 'p:pro:active:!automation' m:team:active:automation s:personal:active:- "$ENDED"
case_ 1 "the Team document only among the cases that do not check" \
  t:trial:active:automation p:pro:active:automation bad:m:team:active:automation s:personal:active:- "$ENDED"
case_ 1 "the Team's only document export-only" \
  t:trial:active:automation p:pro:active:automation m:team:export_only:automation s:personal:active:-
printf 'Service Unavailable' > "$WORK/vectors.json"
out="$(python3 -I "$HERE/automation_plan_gate.py" --vectors "$WORK/vectors.json" 2>&1)"; code=$?
if [[ "$code" == 1 ]]; then echo "ok    (1) not the server's vectors at all: $out"; else echo "WRONG (exit $code) not the server's vectors: $out"; status=1; fi
out="$(python3 -I "$HERE/automation_plan_gate.py" --vectors "$WORK/none.json" 2>&1)"; code=$?
if [[ "$code" == 1 ]]; then echo "ok    (1) no file: $out"; else echo "WRONG (exit $code) no file: $out"; status=1; fi

# release.sh itself, asked for a signed release (a made-up Developer ID; the gate is its step 0a,
# before anything is built or GitHub is asked). It reads the app's own copy of the server's vectors
# and takes no other, so the control follows that copy: while the gate says no on it, the release
# must stop there, for that reason; once it says yes there is nothing left to refuse.
if python3 -I "$HERE/automation_plan_gate.py" --vectors "$HERE/../Tests/BrowserCoreTests/Fixtures/entitlement-test-vectors.json" > /dev/null 2>&1; then
  echo "ok    the app's copy of the server's vectors shows automation signed by plan: release.sh has nothing to refuse"
else
  out="$(SIGN_IDENTITY='Developer ID Application: Made Up (ABCDE12345)' VERSION=0.0.1 BUILD=1 OUT="$WORK/release" "$HERE/release.sh" 2>&1)"; code=$?
  if [[ "$code" != 0 && "$out" == *"do not show automation signed by plan"* && "$out" != *"full run:"* && ! -e "$WORK/release" ]]; then
    echo "ok    ($code) release.sh, asked for a signed release, stops before anything else: $(echo "$out" | tail -n 1)"
  else
    echo "WRONG (exit $code) release.sh, asked for a signed release while the vectors show no automation by plan:"
    echo "$out" | tail -n 20
    status=1
  fi
fi

(( status == 0 )) && echo "automation plan gate: every case answered as it must" || echo "automation plan gate: FAILED"
exit $status
