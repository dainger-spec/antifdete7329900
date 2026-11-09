#!/usr/bin/env bash
# `Lumen --guard-diagnose` where no guard can run (CI), as far as it goes without one.
#
#   scripts/guard_diagnose_check.sh build/unsandboxed      (the folder of an NE=check build)
#
# The diagnosis (GuardDiagnosis.swift) measures the network guard on a Mac where it is installed —
# the owner's; CI cannot load the extension. What CI can show is that it starts, reads what it
# reads, says in words where it stops, and does not pass: two runs.
#   1. The app as CI builds it (NE=check: no guard inside) must say it has none.
#   2. A copy with the extension laid inside, as an NE=1 build has it (ad hoc: CI has no team), must
#      name its guard, ask systemextensionsctl and NEFilterManager, say it cannot ask a guard signed
#      by no team, and print its answers.
#   3. The same copy with the listing of a Mac where an earlier copy waits for the restart must say
#      so on its first line (the owner's Mac after updating to 0.1.3).
# Any run fails this when it crashes, hangs (60 s), exits 0 — a pass where no guard runs would
# be a false one — or leaves out a section the owner's run needs.
set -euo pipefail

dir="${1:?the folder of an NE=check build, e.g. build/unsandboxed}"
app="$dir/Lumen.app"
extension="$(find "$dir" -maxdepth 1 -name '*.systemextension' -type d | head -1)"
[[ -d "$app" ]] || { echo "error: no $app" >&2; exit 1; }
[[ -n "$extension" ]] || { echo "error: no extension beside $app (NE=check lays it there)" >&2; exit 1; }
identifier="$(basename "$extension" .systemextension)"
work="$(mktemp -d "${TMPDIR:-/tmp}/pbdiagnose.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failed=0

# run <app> <name>: the diagnosis, 60 s at most (perl's alarm: macOS has no timeout(1)); prints its
# output and leaves its exit status in $status.
run() {
  local out="$work/$2.txt"
  status=0
  perl -e 'alarm shift; exec @ARGV' 60 "$1/Contents/MacOS/Lumen" --guard-diagnose >"$out" 2>&1 || status=$?
  echo "---- $2: exit $status"
  cat "$out"
  echo "----"
}

# expect <name> <text>: the run's output holds the text, or this fails.
expect() {
  if grep -qF -- "$2" "$work/$1.txt"; then
    echo "OK   $1 says: $2"
  else
    echo "FAIL $1 does not say: $2"
    failed=1
  fi
}

expect_status() {
  if [[ "$status" == "1" ]]; then
    echo "OK   $1 exits 1 (the check does not pass where no guard runs)"
  else
    echo "FAIL $1 exits $status, not 1$( [[ "$status" == "142" ]] && echo ': it hung for 60 s and was ended' )"
    failed=1
  fi
}

run "$app" as-built
expect_status as-built
expect as-built "Lumen's network guard on this Mac"
expect as-built "== ANSWERS"
expect as-built "has no network guard in it"

copy="$work/Lumen.app"
ditto "$app" "$copy"
mkdir -p "$copy/Contents/Library/SystemExtensions"
ditto "$extension" "$copy/Contents/Library/SystemExtensions/$identifier.systemextension"
/usr/libexec/PlistBuddy -c "Add :PBGuardExtensionBundleIdentifier string $identifier" "$copy/Contents/Info.plist"
codesign --force --sign - "$copy/Contents/Library/SystemExtensions/$identifier.systemextension"
codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$copy"
run "$copy" with-guard
expect_status with-guard
expect with-guard "its guard: $identifier, version"
expect with-guard "== The system extension (systemextensionsctl list)"
expect with-guard "== The filter's configuration (NEFilterManager)"
if grep -qE '^(enabled: |could not be read: |not given in 10 s|no provider configuration)' "$work/with-guard.txt"; then
  echo "OK   with-guard says what the filter's configuration is, or why it could not be read"
else
  echo "FAIL with-guard says nothing of the filter's configuration"
  failed=1
fi
expect with-guard "== The guard, asked over XPC"
expect with-guard "signed by no team"
expect with-guard "== ANSWERS"
expect with-guard "1. Does the filter receive flows? UNKNOWN"
expect with-guard "The check: CANNOT RUN"
# 3. The owner's Mac after an update (0.1.3): macOS keeps the earlier copy until the next restart.
#    The listing as systemextensionsctl gives it there; the first line must say to restart.
cat >"$work/list.txt" <<LIST
2 extension(s)
--- com.apple.system_extension.network_extension
enabled	active	teamID	bundleID (version)	name	[state]
*	*	ABCDE12345	$identifier (0.1.3/4)	Lumen Network Guard	[activated enabled]
		ABCDE12345	$identifier (0.1.2/3)	Lumen Network Guard	[terminated waiting to uninstall on reboot]
LIST
status=0
PB_GUARD_DIAGNOSE_EXTENSIONS_LIST="$work/list.txt" perl -e 'alarm shift; exec @ARGV' 60 "$copy/Contents/MacOS/Lumen" --guard-diagnose \
  >"$work/restart.txt" 2>&1 || status=$?
echo "---- restart: exit $status"; cat "$work/restart.txt"; echo "----"
expect_status restart
if head -1 "$work/restart.txt" | grep -q "^RESTART THIS MAC:"; then
  echo "OK   restart says to restart the Mac, on its first line"
else
  echo "FAIL restart's first line is not the restart: $(head -1 "$work/restart.txt")"
  failed=1
fi
if head -1 "$work/with-guard.txt" | grep -q "RESTART"; then
  echo "FAIL with-guard (nothing waits for a restart) says to restart"
  failed=1
fi
if grep -q "The check: PASSES" "$work/as-built.txt" "$work/with-guard.txt"; then
  echo "FAIL a run says the check passes where no guard runs"
  failed=1
fi

if [[ "$failed" != "0" ]]; then
  echo "GUARD-DIAGNOSE-CHECK FAILED"
  exit 1
fi
echo "GUARD-DIAGNOSE-CHECK PASSED: it starts, says where it stops without a guard, and does not pass"
