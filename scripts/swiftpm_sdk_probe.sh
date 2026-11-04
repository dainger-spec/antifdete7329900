#!/bin/bash
# Which SDK version an executable built by SwiftPM declares in its LC_BUILD_VERSION, and how it can
# be made to declare the SDK it was built with. On the owner's Mac (Xcode 27.1) the app declares
# "minos 14.0, sdk 14.0" — the platform in Package.swift twice — where Xcode writes the SDK's own
# version, and frameworks that follow the SDK (WebKit, AppKit) then behave as for a 2023 app.
#
#   scripts/swiftpm_sdk_probe.sh <out dir> <notice title>
#
# A throwaway package (one file that prints a word) is built in a temporary folder: as this project
# declares its platform; with macOS 26 declared; with the linker given the SDK's version; with the
# SDK named to the compiler; and by swiftc alone. Each prints what the executable declares and the
# -platform_version the linker was given, as the verbose build shows it. A measurement: it never fails.
set -u
out="$1"
title="$2"
mkdir -p "$out"
version="$(xcrun --show-sdk-version)"
path="$(xcrun --show-sdk-path)"
arch="$(uname -m)"
echo "::notice title=$title::this Xcode: $(xcodebuild -version 2>/dev/null | head -1), its SDK $version"

scratch="$(mktemp -d)"
if [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
  echo "::warning title=$title::no temporary folder"
  exit 0
fi
package="$scratch/Probe"
mkdir -p "$package/Sources/Probe"
echo 'print("probe")' > "$package/Sources/Probe/main.swift"

# <platform declaration>
manifest() {
  cat > "$package/Package.swift" <<EOF
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Probe", platforms: [$1], targets: [.executableTarget(name: "Probe", path: "Sources/Probe")])
EOF
}

# <name> <executable> <build log> <exit status>
report() {
  local declared passed
  declared="$(xcrun vtool -show-build "$2" 2>/dev/null | awk '$1 == "minos" || $1 == "sdk" { printf "%s %s, ", $1, $2 }')"
  passed="$(grep -o -- '-platform_version [^ ]* [^ ]* [^ ]*' "$3" 2>/dev/null | sort -u | tr '\n' ';')"
  echo "SWIFTPM-SDK $1: exit $4; declares ${declared:-nothing}linker given: ${passed:-not seen}" | tee -a "$out/swiftpm-sdk.txt" \
    | cut -c1-500 | sed "s/^/::notice title=$title::/"
  [ "$4" = 0 ] || tail -3 "$3" | sed "s/^/    /"
}

# <name> <platform declaration> [swift build options…]
package_build() {
  local name="$1" platform="$2"
  shift 2
  manifest "$platform"
  rm -rf "$package/.build"
  (cd "$package" && swift build -c release -v -Xswiftc -v "$@") > "$out/$name.log" 2>&1
  local status=$?
  report "$name" "$package/.build/release/Probe" "$out/$name.log" "$status"
}

package_build "as this project declares (.macOS(.v14))" ".macOS(.v14)"
# clang, the linker's driver, shows the ld command it runs — and the -platform_version in it.
package_build "as this project declares, the link shown" ".macOS(.v14)" -Xswiftc -Xclang-linker -Xswiftc -v
package_build "macOS 26 declared" '.macOS("26.0")'
package_build "macOS 26, the linker given the SDK's version" '.macOS("26.0")' \
  -Xlinker -platform_version -Xlinker macos -Xlinker 26.0 -Xlinker "$version"
package_build "macOS 26, the SDK named to the compiler" '.macOS("26.0")' -Xswiftc -sdk -Xswiftc "$path"

(cd "$package" && xcrun swiftc -v -target "$arch-apple-macosx26.0" -sdk "$path" Sources/Probe/main.swift -o "$scratch/probe-swiftc") \
  > "$out/swiftc.log" 2>&1
report "swiftc alone, macOS 26 target" "$scratch/probe-swiftc" "$out/swiftc.log" "$?"

rm -rf "$scratch"
exit 0
