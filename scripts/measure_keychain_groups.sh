#!/usr/bin/env bash
# A measurement (never merged): which signatures reach the data-protection keychain on a CI runner,
# where nothing can be signed by an Apple-issued certificate. An NE=1 build carries
# com.apple.application-identifier and the app group <TEAM>.io.lumenbrowser.Lumen; a profile's
# process runs the app's own executable. Whether an ad-hoc signature with the app group alone opens
# the data-protection keychain decides whether CI can show one profile's items seen from another.
set -u
W="$(mktemp -d)"
cat > "$W/kc.swift" <<'SWIFT'
import Foundation
import Security
let arguments = CommandLine.arguments
let service = "pb-measure-keychain-groups"
func say(_ status: OSStatus) -> String { "\(status) (\((SecCopyErrorMessageString(status, nil) as String?) ?? "?"))" }
var base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecUseDataProtectionKeychain as String: true]
switch arguments.count > 1 ? arguments[1] : "" {
case "add":
    var query = base
    query[kSecAttrAccount as String] = arguments[2]
    query[kSecValueData as String] = Data("marker".utf8)
    print("add \(arguments[2]): \(say(SecItemAdd(query as CFDictionary, nil)))")
case "find":
    var query = base
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnAttributes as String] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    let items = (result as? [[String: Any]]) ?? []
    print("find: \(say(status)) \(items.map { "\($0[kSecAttrAccount as String] ?? "?")@\($0[kSecAttrAccessGroup as String] ?? "?")" })")
case "delete":
    print("delete: \(say(SecItemDelete(base as CFDictionary)))")
default:
    print("usage: kc add <account> | find | delete")
}
SWIFT
swiftc -O "$W/kc.swift" -o "$W/kc" || { echo "MEASURE-KEYCHAIN could not build the probe"; exit 1; }

entitlements() {  # name, then key=value pairs (value "group:<g>" = an array of one string)
  local file="$W/$1.entitlements"; shift
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>\n' > "$file"
  for pair in "$@"; do
    local key="${pair%%=*}" value="${pair#*=}"
    if [[ "$value" == group:* ]]; then
      printf '<key>%s</key><array><string>%s</string></array>\n' "$key" "${value#group:}" >> "$file"
    else
      printf '<key>%s</key><string>%s</string>\n' "$key" "$value" >> "$file"
    fi
  done
  printf '</dict></plist>\n' >> "$file"
  plutil -lint "$file" >/dev/null || { echo "bad entitlements $file"; cat "$file"; }
  echo "$file"
}

TEAM=XXXXXXXXXX
GROUP="$TEAM.io.lumenbrowser.Lumen"
probe() {  # name, entitlements file or "", signing identifier
  cp "$W/kc" "$W/$1"
  if [[ -n "$2" ]]; then
    codesign --force --options runtime --sign - --identifier "$3" --entitlements "$2" "$W/$1" 2>&1 | sed "s/^/  codesign $1: /"
  else
    codesign --force --options runtime --sign - --identifier "$3" "$W/$1" 2>&1 | sed "s/^/  codesign $1: /"
  fi
  codesign -d --entitlements - --xml "$W/$1" 2>/dev/null | tr -d '\n' | sed "s/^/  entitlements $1: /"; echo
}
probe kc-none "" io.lumenbrowser.Lumen
probe kc-groupA "$(entitlements groupA com.apple.security.application-groups=group:$GROUP)" io.lumenbrowser.Lumen
probe kc-groupB "$(entitlements groupB com.apple.security.application-groups=group:$GROUP)" io.lumenbrowser.Lumen.other
probe kc-groupC "$(entitlements groupC com.apple.security.application-groups=group:YYYYYYYYYY.org.example.other)" org.example.other
probe kc-appid "$(entitlements appid com.apple.application-identifier=$GROUP com.apple.developer.team-identifier=$TEAM)" io.lumenbrowser.Lumen
probe kc-kag "$(entitlements kag keychain-access-groups=group:$GROUP)" io.lumenbrowser.Lumen

run() {  # name, arguments…
  local name="$1"; shift
  local output status
  output="$(cd "$W" && perl -e 'alarm shift; exec @ARGV' 60 "./$name" "$@" 2>&1)"; status=$?
  echo "MEASURE-KEYCHAIN $name $* → exit $status: ${output//$'\n'/ | }"
}
echo "MEASURE-KEYCHAIN on $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), user $(id -un), session $(launchctl managername 2>/dev/null)"
security list-keychains | sed 's/^/  keychains: /'
run kc-groupA delete
run kc-none add none-1
run kc-none find
run kc-groupA add groupA-1
run kc-groupA find
run kc-groupB find
run kc-groupC find
run kc-none find
run kc-appid add appid-1
run kc-appid find
run kc-kag add kag-1
run kc-kag find
run kc-groupB add groupB-1
run kc-groupA find
run kc-groupA delete
run kc-appid delete
run kc-kag delete
run kc-groupA find
log show --last 3m --style compact --predicate 'process == "amfid" OR (process == "kernel" AND eventMessage CONTAINS "AMFI")' 2>/dev/null | grep -i "kc-" | tail -20 | sed 's/^/  amfi: /'
