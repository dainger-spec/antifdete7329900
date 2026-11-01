#!/bin/bash
# The interface's language as the app starts, from each place it can come from (CI):
#
#   scripts/interface_language_check.sh build/unsandboxed/Lumen.app
#
# Until 1 November the interface was Russian whatever the Mac or the command line said, and every
# start wrote AppleLanguages = (ru, en) into the app's preferences on disk: the owner's
# `open Lumen.app --args -AppleLanguages "(en)"` came up in Russian (measured in CI run 577: the
# English tables were in the bundle, the code chose Russian). Each case below would have failed
# then; the "(ru)" and "(en)" cases fail a build that answers one language whatever it is asked.
set -u
APP="${1:?the app bundle}"
BINARY="$APP/Contents/MacOS/Lumen"
DOMAIN=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
failures=0

# The first of this Mac's languages the app is translated into, else English (InterfaceLanguage).
SYSTEM=$(defaults read -g AppleLanguages 2>/dev/null | tr -d ' ",()' | grep -v '^$' \
         | sed 's/-.*//' | grep -m1 -E '^(ru|en)$' || true)
SYSTEM=${SYSTEM:-en}
echo "this Mac's languages: $(defaults read -g AppleLanguages 2>/dev/null | tr -d '\n ')" "-> expected by default: $SYSTEM"

clean() {
  defaults delete "$DOMAIN" AppleLanguages >/dev/null 2>&1
  defaults delete "$DOMAIN" PBInterfaceLanguage >/dev/null 2>&1
}

# expect NAME KEY=VALUE... -- ARGUMENTS...: runs the app's check with the arguments and compares.
expect() {
  local name="$1"; shift
  local wanted=()
  while [ "$1" != "--" ]; do wanted+=("$1"); shift; done
  shift
  local output
  output=$("$BINARY" --interface-language-check "$@" 2>/dev/null | grep '^INTERFACE-LANGUAGE ')
  compare "$name" "$output" "${wanted[@]}"
}

compare() {
  local name="$1" output="$2"; shift 2
  local missing=()
  for pair in "$@"; do
    grep -qxF "INTERFACE-LANGUAGE $pair" <<<"$output" || missing+=("$pair")
  done
  if [ -z "$output" ]; then
    echo "FAIL $name: the check printed nothing"
    failures=$((failures + 1))
  elif [ ${#missing[@]} -eq 0 ]; then
    echo "PASS $name: $(tr '\n' ' ' <<<"${output//INTERFACE-LANGUAGE /}")"
  else
    echo "FAIL $name: wanted ${missing[*]}; got $(tr '\n' ' ' <<<"${output//INTERFACE-LANGUAGE /}")"
    failures=$((failures + 1))
  fi
}

word() { [ "$1" = ru ] && echo "word=О приложении" || echo "word=About"; }

clean
expect "nothing chosen: this Mac's language" "language=$SYSTEM" "$(word "$SYSTEM")" "bundles=$SYSTEM" "onDiskAfter=none" --
expect "-AppleLanguages (ru)" "language=ru" "word=О приложении" "bundles=ru" "appKit=ru" -- -AppleLanguages "(ru)"
expect "-AppleLanguages (en)" "language=en" "word=About" "bundles=en" "appKit=en" -- -AppleLanguages "(en)"
expect "-AppleLanguages (de-DE, ru-RU): the first the app speaks" "language=ru" -- -AppleLanguages "(de-DE, ru-RU)"

# As the owner started it: through LaunchServices, with the app closed.
out=$(mktemp)
open -W --stdout "$out" --stderr /dev/null "$APP" --args --interface-language-check -AppleLanguages "(en)"
compare "open --args -AppleLanguages (en), as the owner did" "$(grep '^INTERFACE-LANGUAGE ' "$out")" "language=en" "word=About" "bundles=en"
rm -f "$out"

# The person's choice (Settings › Language, the first screen); -AppleLanguages still wins for its run.
defaults write "$DOMAIN" PBInterfaceLanguage ru
expect "chosen: Russian" "language=ru" "choice=ru" "word=О приложении" "bundles=ru" --
expect "chosen: Russian, run with -AppleLanguages (en)" "language=en" "choice=ru" "bundles=en" -- -AppleLanguages "(en)"
defaults write "$DOMAIN" PBInterfaceLanguage en
expect "chosen: English" "language=en" "choice=en" "word=About" "bundles=en" --
clean

# What earlier versions wrote at every start is taken out once, and no longer decides anything.
defaults write "$DOMAIN" AppleLanguages -array ru en
expect "after an earlier version's (ru, en)" "language=$SYSTEM" "onDiskBefore=ru,en" "onDiskAfter=none" "bundles=$SYSTEM" --
expect "and the next start" "language=$SYSTEM" "onDiskBefore=none" "onDiskAfter=none" --
# A list the person set for this app stays.
defaults write "$DOMAIN" AppleLanguages -array de
expect "a list the person set (de) stays" "onDiskBefore=de" "onDiskAfter=de" --
clean

if [ "$failures" -gt 0 ]; then
  echo "interface language: $failures case(s) failed"
  exit 1
fi
echo "interface language: every case passed"
