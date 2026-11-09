#!/bin/bash
# scripts/safari_reference.py against saved answers: what Safari said under WebDriver, what a plain
# Safari window said, and the profile's surface. Each outcome must be told apart by the script itself
# (CI run 718: "Safari's canvas threw" — the profile's fault, or the driver's?): a probe that came
# back short is NOT DRIVEN; a difference a plain window repeats DIVERGES; one a plain window does not
# repeat is WEBDRIVER ONLY; a plain window that gave nothing excuses nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
status=0

# A surface as the probe writes it: every top-level key, canvas as an object.
surface() { # <canvas colors> <safari>
  python3 - "$1" "$2" <<'EOF'
import json, sys
s = {f"k{i}": "same" for i in range(45)}
s.update({"ua": "Mozilla/5.0 Version/27.2 Safari/605.1.15", "canvas": {"colors": sys.argv[1], "urlLength": "274"},
          "safari": sys.argv[2], "language": "en-US"})
print(json.dumps(s))
EOF
}
surface 5 "[object Object]" > "$WORK/profile.json"
case_() { # <expected exit> <what> <safari json> <plain json or none>
  printf '%s' "$3" > "$WORK/safari.json"
  plain=none
  if [[ "$4" != none ]]; then printf '%s' "$4" > "$WORK/plain.json"; plain="$WORK/plain.json"; fi
  out="$(python3 -I "$HERE/safari_reference.py" --compare "$WORK/profile.json" --safari-json "$WORK/safari.json" --plain-json "$plain" 2>&1)"
  code=$?
  last="$(printf '%s\n' "$out" | grep '^SAFARI-REFERENCE' | tail -1)"
  if [[ "$code" == "$1" ]]; then echo "ok    ($code) $2: $last"; else echo "WRONG (exit $code, wanted $1) $2:"; echo "$out"; status=1; fi
}

same="$(surface 5 "[object Object]")"
canvas_differs="$(surface error "[object Object]")"
short='{"ua": "Mozilla/5.0 Version/27.2 Safari/605.1.15", "canvas": {"colors": "5"}}'

case_ 0 "every must-match key the same" "$same" none
case_ 2 "Safari's probe came back without most of its keys (the driver failed)" "$short" none
case_ 1 "canvas differs, and a plain Safari window says what WebDriver said" "$canvas_differs" "$canvas_differs"
case_ 3 "canvas differs under WebDriver only: a plain Safari window says what the profile says" "$canvas_differs" "$same"
case_ 1 "canvas differs, and no plain window could be read (nothing excuses it)" "$canvas_differs" none
case_ 1 "canvas differs, and a plain window says a third thing" "$canvas_differs" "$(surface 7 "[object Object]")"

# Safari with a WebKit of its own (run 718): nothing compared; the profile must name its own engine's Safari.
engine() { # <declared> <ua version>
  python3 - "$1" "$2" "$WORK/profile-one-engine.json" <<'EOF'
import json, sys
s = json.load(open(sys.argv[3]))
s["_engine"] = {"webKit": "21624.5.1.11.3", "safariApp": "27.2", "safariAppBuild": "22627.1", "declared": sys.argv[1], "sharesEngine": "false"}
s["ua"] = f"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/{sys.argv[2]} Safari/605.1.15"
print(json.dumps(s))
EOF
}
cp "$WORK/profile.json" "$WORK/profile-one-engine.json"
engine 26.6.2 26.6.2 > "$WORK/profile.json"
case_ 4 "Safari runs a WebKit of its own; the profile names its own engine's Safari" "$canvas_differs" none
engine 26.6.2 27.2 > "$WORK/profile.json"
case_ 1 "Safari runs a WebKit of its own; the profile still calls itself Safari.app's version (0.1.2's way)" "$canvas_differs" none
cp "$WORK/profile-one-engine.json" "$WORK/profile.json"

# No surface from the self-test (it stopped before writing one): nothing compared, never "differs".
out="$(python3 -I "$HERE/safari_reference.py" --compare "$WORK/absent.json" --safari-json "$WORK/safari.json" --plain-json none 2>&1)"
code=$?
if [[ "$code" == 2 ]]; then echo "ok    (2) no surface from the self-test: $(printf '%s\n' "$out" | tail -1)"; else echo "WRONG (exit $code, wanted 2) no surface: $out"; status=1; fi

exit $status
