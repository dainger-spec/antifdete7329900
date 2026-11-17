#!/usr/bin/env bash
# Builds the `openvpn` that Lumen's OpenVPN connections run (docs/OPENVPN.md): OpenVPN 2.7 from its
# release tarball, unchanged — no patch: its AF_UNIX tun (`--dev-node unix:`) is what lets it run
# without root — with mbed TLS 3.6 (Apache-2.0 OR GPL-2.0-or-later), LZO 2.10 and LZ4 1.10 linked in
# statically. Every source is pinned by version and SHA-256; a download that does not match is
# refused.
#
#   scripts/build-openvpn.sh [out folder]          (default build/openvpn)
#   ARCHS="arm64 x86_64" scripts/build-openvpn.sh  (a universal binary; default: this Mac's)
#
# Leaves <out>/openvpn (stripped), <out>/licenses/ (each project's license text, and SOURCES.txt:
# where each source came from, its SHA-256, and that OpenVPN is unmodified) — what build-app.sh puts
# into the app with OVPN=1. A finished build of the same pins and architectures is reused.
#
# Needs only what macOS and Xcode's command line tools have: curl, shasum, tar, make, clang, ar,
# lipo, strip and otool. No CMake, autotools, pkg-config or anything from Homebrew: each tarball
# carries its own configure script or Makefile, mbed TLS's with its generated files, and every
# library's flags are given to OpenVPN's configure directly.
set -euo pipefail
cd "$(dirname "$0")/.."

OPENVPN_VERSION=2.7.9
OPENVPN_SHA256=c42a6ed892ddfe2d6e3317a5040f19bec5827564affb2fe3f2b3904a94daacb1
OPENVPN_URLS=("https://swupdate.openvpn.org/community/releases/openvpn-$OPENVPN_VERSION.tar.gz"
              "https://github.com/OpenVPN/openvpn/releases/download/v$OPENVPN_VERSION/openvpn-$OPENVPN_VERSION.tar.gz")
MBEDTLS_VERSION=3.6.5
MBEDTLS_SHA256=4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8
MBEDTLS_URLS=("https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2")
LZO_VERSION=2.10
LZO_SHA256=c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072
LZO_URLS=("https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO_VERSION.tar.gz")
LZ4_VERSION=1.10.0
LZ4_SHA256=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
LZ4_URLS=("https://github.com/lz4/lz4/releases/download/v$LZ4_VERSION/lz4-$LZ4_VERSION.tar.gz")

for tool in curl shasum tar make clang ar lipo strip otool; do
  command -v "$tool" >/dev/null || { echo "error: build-openvpn.sh needs $tool (Xcode's command line tools: xcode-select --install)" >&2; exit 1; }
done

OUT="${1:-build/openvpn}"
ARCHS="${ARCHS:-$(uname -m)}"
MINIMUM_MACOS=14.0
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAMP="openvpn $OPENVPN_VERSION $OPENVPN_SHA256 mbedtls $MBEDTLS_VERSION make lzo $LZO_VERSION lz4 $LZ4_VERSION archs $ARCHS macos $MINIMUM_MACOS"
if [[ -x "$OUT/openvpn" && -f "$OUT/STAMP" && "$(cat "$OUT/STAMP")" == "$STAMP" ]]; then
  echo "OpenVPN: reusing $OUT/openvpn ($STAMP)"
  exit 0
fi
rm -f "$OUT/openvpn" "$OUT/STAMP"
SRC="$OUT/src"
WORK="$OUT/work"
rm -rf "$WORK"
mkdir -p "$SRC" "$WORK"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

# Fetches a source into $SRC, from the first of its addresses that answers, and checks its SHA-256.
fetch() {
  local file=$1 sum=$2
  shift 2
  if [[ -f "$SRC/$file" ]] && echo "$sum  $SRC/$file" | shasum -a 256 -c - >/dev/null 2>&1; then return 0; fi
  rm -f "$SRC/$file"
  for url in "$@"; do
    if curl -fsSL --retry 3 --connect-timeout 20 -o "$SRC/$file.part" "$url"; then
      if echo "$sum  $SRC/$file.part" | shasum -a 256 -c - >/dev/null 2>&1; then
        mv "$SRC/$file.part" "$SRC/$file"
        return 0
      fi
      echo "error: $url does not have the pinned SHA-256 ($sum): refused" >&2
      rm -f "$SRC/$file.part"
    fi
  done
  echo "error: $file could not be fetched with its pinned SHA-256" >&2
  exit 1
}
fetch "openvpn-$OPENVPN_VERSION.tar.gz" "$OPENVPN_SHA256" "${OPENVPN_URLS[@]}"
fetch "mbedtls-$MBEDTLS_VERSION.tar.bz2" "$MBEDTLS_SHA256" "${MBEDTLS_URLS[@]}"
fetch "lzo-$LZO_VERSION.tar.gz" "$LZO_SHA256" "${LZO_URLS[@]}"
fetch "lz4-$LZ4_VERSION.tar.gz" "$LZ4_SHA256" "${LZ4_URLS[@]}"

build_arch() {
  local arch=$1
  local host
  case "$arch" in
    arm64) host=aarch64-apple-darwin ;;
    x86_64) host=x86_64-apple-darwin ;;
    *) echo "error: unknown architecture $arch" >&2; exit 1 ;;
  esac
  local dir="$WORK/$arch" prefix="$WORK/$arch/prefix"
  local flags="-arch $arch -mmacosx-version-min=$MINIMUM_MACOS -O2 -fstack-protector-strong"
  mkdir -p "$dir" "$prefix"
  tar -xf "$SRC/mbedtls-$MBEDTLS_VERSION.tar.bz2" -C "$dir"
  tar -xf "$SRC/lzo-$LZO_VERSION.tar.gz" -C "$dir"
  tar -xf "$SRC/lz4-$LZ4_VERSION.tar.gz" -C "$dir"
  tar -xf "$SRC/openvpn-$OPENVPN_VERSION.tar.gz" -C "$dir"
  echo "OpenVPN: mbed TLS $MBEDTLS_VERSION ($arch)"
  # Its own Makefile, the library alone, in its default configuration (as its CMake build makes it):
  # the release tarball holds every generated file, so nothing is generated (GEN_FILES empty) and
  # neither CMake nor Python is needed.
  (cd "$dir/mbedtls-$MBEDTLS_VERSION" && make -j "$JOBS" lib CC=clang CFLAGS="$flags" GEN_FILES= > "$dir/mbedtls.log" 2>&1) \
    || { tail -40 "$dir/mbedtls.log" >&2; echo "error: mbed TLS did not build ($arch); see $dir/mbedtls.log" >&2; exit 1; }
  mkdir -p "$prefix/include" "$prefix/lib"
  cp -R "$dir/mbedtls-$MBEDTLS_VERSION/include/mbedtls" "$dir/mbedtls-$MBEDTLS_VERSION/include/psa" "$prefix/include/"
  cp "$dir/mbedtls-$MBEDTLS_VERSION/library/libmbedtls.a" "$dir/mbedtls-$MBEDTLS_VERSION/library/libmbedx509.a" \
    "$dir/mbedtls-$MBEDTLS_VERSION/library/libmbedcrypto.a" "$prefix/lib/"
  echo "OpenVPN: LZO $LZO_VERSION ($arch)"
  (cd "$dir/lzo-$LZO_VERSION" && ./configure --host="$host" --prefix="$prefix" --disable-shared --enable-static CC=clang CFLAGS="$flags" \
    > "$dir/lzo.log" 2>&1 && make -j "$JOBS" >> "$dir/lzo.log" 2>&1 && make install >> "$dir/lzo.log" 2>&1) \
    || { tail -40 "$dir/lzo.log" >&2; echo "error: LZO did not build ($arch); see $dir/lzo.log" >&2; exit 1; }
  echo "OpenVPN: LZ4 $LZ4_VERSION ($arch)"
  (cd "$dir/lz4-$LZ4_VERSION/lib" && make -j "$JOBS" liblz4.a CC=clang CFLAGS="$flags" > "$dir/lz4.log" 2>&1) \
    || { tail -40 "$dir/lz4.log" >&2; echo "error: LZ4 did not build ($arch); see $dir/lz4.log" >&2; exit 1; }
  mkdir -p "$prefix/include" "$prefix/lib"
  cp "$dir/lz4-$LZ4_VERSION/lib/"{lz4.h,lz4hc.h,lz4frame.h} "$prefix/include/"
  cp "$dir/lz4-$LZ4_VERSION/lib/liblz4.a" "$prefix/lib/"
  echo "OpenVPN: OpenVPN $OPENVPN_VERSION ($arch)"
  # Only static libraries in the prefix: what -l finds there is linked in.
  (cd "$dir/openvpn-$OPENVPN_VERSION" && ./configure --host="$host" --with-crypto-library=mbedtls CC=clang \
    --disable-plugins --disable-plugin-auth-pam --disable-plugin-down-root --disable-dco --disable-unit-tests \
    --disable-port-share --disable-ntlm --enable-lzo --enable-lz4 \
    CFLAGS="$flags" LDFLAGS="-arch $arch -L$prefix/lib" \
    MBEDTLS_CFLAGS="-I$prefix/include" MBEDTLS_LIBS="-lmbedtls -lmbedx509 -lmbedcrypto" \
    LZO_CFLAGS="-I$prefix/include" LZO_LIBS="-llzo2" LZ4_CFLAGS="-I$prefix/include" LZ4_LIBS="-llz4" \
    > "$dir/openvpn.log" 2>&1 && make -j "$JOBS" >> "$dir/openvpn.log" 2>&1) \
    || { tail -40 "$dir/openvpn.log" >&2; echo "error: OpenVPN did not build ($arch); see $dir/openvpn.log" >&2; exit 1; }
  cp "$dir/openvpn-$OPENVPN_VERSION/src/openvpn/openvpn" "$WORK/openvpn-$arch"
}

built=()
for arch in $ARCHS; do
  build_arch "$arch"
  built+=("$WORK/openvpn-$arch")
done
if [[ ${#built[@]} -gt 1 ]]; then
  lipo -create "${built[@]}" -output "$WORK/openvpn"
else
  cp "${built[0]}" "$WORK/openvpn"
fi
strip -x "$WORK/openvpn"
# Nothing but the system's own libraries: the TLS, compression and everything else are inside.
if otool -L "$WORK/openvpn" | tail -n +2 | grep -v -E '^\s+/usr/lib/|^\s+/System/Library/' | grep -q .; then
  otool -L "$WORK/openvpn" >&2
  echo "error: the openvpn built links a library outside the system's" >&2
  exit 1
fi
# `openvpn --version` ends with status 1 by design: its words are what is checked.
[[ "$("$WORK/openvpn" --version 2>&1 || true)" == "OpenVPN $OPENVPN_VERSION "* ]] || { echo "error: the openvpn built does not run" >&2; exit 1; }

# What must ship with it: each license, and where its source is.
first="$WORK/${ARCHS%% *}"
rm -rf "$OUT/licenses"
mkdir -p "$OUT/licenses"
cp "$first/openvpn-$OPENVPN_VERSION/COPYING" "$OUT/licenses/OpenVPN-COPYING.txt"
cp "$first/openvpn-$OPENVPN_VERSION/COPYRIGHT.GPL" "$OUT/licenses/OpenVPN-COPYRIGHT.GPL.txt"
cp "$first/mbedtls-$MBEDTLS_VERSION/LICENSE" "$OUT/licenses/MbedTLS-LICENSE.txt"
cp "$first/lzo-$LZO_VERSION/COPYING" "$OUT/licenses/LZO-COPYING.txt"
cp "$first/lz4-$LZ4_VERSION/lib/LICENSE" "$OUT/licenses/LZ4-LICENSE.txt"
cat > "$OUT/licenses/SOURCES.txt" <<EOF
Lumen's openvpn (Contents/MacOS/openvpn) is OpenVPN $OPENVPN_VERSION, built from its release
tarball without any change, by scripts/build-openvpn.sh of Lumen's public repository
(https://github.com/dainger-spec/antifdete7329900), with these sources linked in statically:

  openvpn-$OPENVPN_VERSION.tar.gz   sha256 $OPENVPN_SHA256
      ${OPENVPN_URLS[0]}
      GPL-2.0 (OpenVPN-COPYING.txt, OpenVPN-COPYRIGHT.GPL.txt)
  mbedtls-$MBEDTLS_VERSION.tar.bz2  sha256 $MBEDTLS_SHA256
      ${MBEDTLS_URLS[0]}
      Apache-2.0 OR GPL-2.0-or-later, used under GPL-2.0-or-later (MbedTLS-LICENSE.txt)
  lzo-$LZO_VERSION.tar.gz           sha256 $LZO_SHA256
      ${LZO_URLS[0]}
      GPL-2.0-or-later (LZO-COPYING.txt)
  lz4-$LZ4_VERSION.tar.gz           sha256 $LZ4_SHA256
      ${LZ4_URLS[0]}
      BSD-2-Clause (LZ4-LICENSE.txt)

The complete corresponding source of this program is those four tarballs and that script. On
request, for three years from the release that shipped it, Lumen's publisher gives a copy of them,
for no more than the cost of making it, to anyone who asks (see docs/LICENSING.md).

openvpn is a separate program: Lumen starts it, it is not linked into Lumen.
EOF
cp "$WORK/openvpn" "$OUT/openvpn"
echo "$STAMP" > "$OUT/STAMP"
rm -rf "$WORK"
ls -l "$OUT/openvpn"
echo "OpenVPN: built $OUT/openvpn ($ARCHS)"
