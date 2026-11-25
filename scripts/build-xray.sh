#!/usr/bin/env bash
# Builds Xray-core from its pinned source (scripts/xray.lock) for macOS, reproducibly, and checks the
# result against the SHA-256 recorded there (docs/TUNNEL.md, "Links").
#
#   scripts/build-xray.sh --arch arm64 --out build/xray/xray-darwin-arm64
#   scripts/build-xray.sh --arch amd64 --out …          # Intel
#   scripts/build-xray.sh --record                      # both architectures; prints the SHA-256 lines and
#                                                       # writes Resources/Xray/NOTICE.txt anew (after a pin change)
#   scripts/build-xray.sh --goos linux --arch amd64 --out … --no-check   # a Linux build, for testing configurations
#   scripts/build-xray.sh --check-notices --out <a build>   # Resources/Xray/NOTICE.txt is what this pin needs
#   GO_VERSION=1.27.5 scripts/build-xray.sh --toolchain-lines   # the lock's toolchain lines for another Go
#
# What makes the bytes the same on every host: the source at the pinned commit (refused if the tag now
# names another), its modules as its go.sum names them (`go mod verify`), the pinned Go toolchain
# (below), CGO off, -trimpath, no VCS stamp, an empty build id, and every variable that changes code
# generation set explicitly. Nothing is downloaded but the source, its modules and the toolchain, all
# checked; no binary of Xray from anywhere.
#
# The Go toolchain is never this Mac's: build-xray.sh fetches Go's own module of the pinned version for
# this host (golang.org/toolchain, the archive `GOTOOLCHAIN` would fetch) from Go's module proxy,
# refuses it unless its SHA-256 is the one scripts/xray.lock records, and keeps it in its cache
# (XRAY_GO_CACHE, default build/xray-src/toolchain) for the next build. Needs: git, curl and unzip —
# what macOS and Xcode's command line tools have; no Go, no Homebrew. Leaves nothing outside its work
# folder (BUILD_ROOT, default build/xray-src), which `--clean` removes, with its module and build
# caches and the toolchain.
set -euo pipefail

cd "$(dirname "$0")/.."
LOCK=scripts/xray.lock
NOTICE=Resources/Xray/NOTICE.txt
# The lock's KEY=value lines (macOS's bash 3.2 cannot `source` a process substitution).
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || continue
  [[ "$value" =~ ^[A-Za-z0-9._:/+-]+$ ]] || { echo "error: $LOCK: the value of $key is not a plain word" >&2; exit 1; }
  printf -v "$key" '%s' "$value"
done < "$LOCK"

ARCH=""
GOOS_TARGET=darwin
OUT=""
CHECK=1
RECORD=0
CLEAN=0
CHECK_NOTICES=0
TOOLCHAIN_LINES=0
BUILD_ROOT="${BUILD_ROOT:-$PWD/build/xray-src}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --goos) GOOS_TARGET="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-check) CHECK=0; shift ;;
    --record) RECORD=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --check-notices) CHECK_NOTICES=1; shift ;;
    --toolchain-lines) TOOLCHAIN_LINES=1; shift ;;
    *) echo "usage: $0 [--arch arm64|amd64] [--goos darwin|linux] [--out path] [--no-check] [--record] [--clean] [--toolchain-lines]" >&2; exit 64 ;;
  esac
done

if [[ "$CLEAN" == "1" ]]; then
  [[ -d "$BUILD_ROOT" ]] && chmod -R u+w "$BUILD_ROOT" 2>/dev/null || true
  rm -rf "$BUILD_ROOT"
  echo "Removed $BUILD_ROOT"
  exit 0
fi

for tool in git curl unzip; do
  command -v "$tool" >/dev/null || { echo "error: build-xray.sh needs $tool" >&2; exit 1; }
done

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Go's module proxy: where the toolchain and Xray's modules come from (both checked, wherever from).
GO_MODULE_PROXY="${GOPROXY:-https://proxy.golang.org}"
GO_MODULE_PROXY="${GO_MODULE_PROXY%%,*}"
[[ "$GO_MODULE_PROXY" == https://* ]] || GO_MODULE_PROXY=https://proxy.golang.org

# The lock's toolchain lines for GO_VERSION: each host's archive fetched, its h1: (Go's dirhash, what
# its checksum database logs) worked out and compared with sum.golang.org's, then its SHA-256 printed.
if [[ "$TOOLCHAIN_LINES" == "1" ]]; then
  command -v python3 >/dev/null || { echo "error: --toolchain-lines needs python3" >&2; exit 1; }
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  for host in darwin_arm64 darwin_amd64 linux_amd64 linux_arm64; do
    module="v0.0.1-go$GO_VERSION.${host/_/-}"
    curl -fsSL --retry 3 -o "$work/$module.zip" "$GO_MODULE_PROXY/golang.org/toolchain/@v/$module.zip"
    logged="$(curl -fsSL --retry 3 "https://sum.golang.org/lookup/golang.org/toolchain@$module" \
      | awk -v m="$module" '$1 == "golang.org/toolchain" && $2 == m { print $3 }')"
    mine="$(python3 -I -c 'import sys, zipfile, hashlib, base64
z = zipfile.ZipFile(sys.argv[1])
names = sorted(n for n in z.namelist() if not n.endswith("/"))
lines = "".join(hashlib.sha256(z.read(n)).hexdigest() + "  " + n + "\n" for n in names)
print("h1:" + base64.b64encode(hashlib.sha256(lines.encode()).digest()).decode())' "$work/$module.zip")"
    [[ -n "$logged" && "$mine" == "$logged" ]] \
      || { echo "error: golang.org/toolchain@$module is $mine, and sum.golang.org logs ${logged:-nothing}" >&2; exit 1; }
    echo "GO_SHA256_$host=$(sha256 "$work/$module.zip")"
    echo "#   sum.golang.org: $logged"
  done
  exit 0
fi

# A work folder of its own: the source, Go's module cache and build cache, and the toolchain.
mkdir -p "$BUILD_ROOT"
SRC="$BUILD_ROOT/Xray-core"

# The pinned Go for this host: Go's own toolchain module, its SHA-256 the lock's, from the cache when
# it is there and was checked; fetched and checked otherwise. Nothing of this Mac's own Go is used.
case "$(uname -s)" in
  Darwin) host_os=darwin ;;
  Linux) host_os=linux ;;
  *) echo "error: no pinned Go for $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) host_arch=arm64 ;;
  x86_64|amd64) host_arch=amd64 ;;
  *) echo "error: no pinned Go for the architecture $(uname -m)" >&2; exit 1 ;;
esac
go_key="GO_SHA256_${host_os}_${host_arch}"
go_sha256="${!go_key:-}"
[[ -n "$go_sha256" ]] || { echo "error: $LOCK records no $go_key: no pinned Go for this host" >&2; exit 1; }
GO_CACHE="${XRAY_GO_CACHE:-$BUILD_ROOT/toolchain}"
[[ "$GO_CACHE" == /* ]] || GO_CACHE="$PWD/$GO_CACHE"
GO_MODULE="v0.0.1-go$GO_VERSION.$host_os-$host_arch"
GO_ROOT="$GO_CACHE/go$GO_VERSION.$host_os-$host_arch"
if [[ -x "$GO_ROOT/bin/go" && "$(cat "$GO_ROOT/.checked-sha256" 2>/dev/null)" == "$go_sha256" ]]; then
  echo "Go $GO_VERSION ($host_os/$host_arch): from the cache, $GO_ROOT"
else
  echo "Go $GO_VERSION ($host_os/$host_arch): fetching golang.org/toolchain@$GO_MODULE from $GO_MODULE_PROXY"
  mkdir -p "$GO_CACHE"
  archive="$GO_CACHE/$GO_MODULE.zip"
  rm -rf "$archive" "$GO_ROOT" "$GO_ROOT.unpacking"
  curl -fsSL --retry 3 --connect-timeout 20 -o "$archive.part" "$GO_MODULE_PROXY/golang.org/toolchain/@v/$GO_MODULE.zip" \
    || { rm -f "$archive.part"; echo "error: Go $GO_VERSION could not be fetched from $GO_MODULE_PROXY" >&2; exit 1; }
  fetched="$(sha256 "$archive.part")"
  if [[ "$fetched" != "$go_sha256" ]]; then
    rm -f "$archive.part"
    echo "error: the Go fetched is $fetched, and $LOCK records $go_sha256: refused" >&2
    exit 1
  fi
  mv "$archive.part" "$archive"
  unzip -q "$archive" -d "$GO_ROOT.unpacking"
  mv "$GO_ROOT.unpacking/golang.org/toolchain@$GO_MODULE" "$GO_ROOT"
  rm -rf "$GO_ROOT.unpacking" "$archive"
  # A module's archive need not keep the files' modes: its programs are made executable, as Go does.
  chmod -R u+w "$GO_ROOT"
  find "$GO_ROOT/bin" "$GO_ROOT/pkg/tool" -type f -exec chmod 755 {} +
  echo "$go_sha256" > "$GO_ROOT/.checked-sha256"
  echo "Go $GO_VERSION ($host_os/$host_arch): checked against $LOCK and kept in $GO_ROOT"
fi
export GOROOT="$GO_ROOT"
export PATH="$GO_ROOT/bin:$PATH"
export GOPATH="$BUILD_ROOT/gopath"
export GOMODCACHE="$BUILD_ROOT/gopath/pkg/mod"
export GOCACHE="$BUILD_ROOT/gocache"
# This Go and no other: never one named by the source's go.mod, nor fetched by Go itself.
export GOTOOLCHAIN=local
export GOFLAGS="-mod=readonly -modcacherw"
export GOPROXY="$GO_MODULE_PROXY"
export GOSUMDB="sum.golang.org"
export GONOSUMDB="" GOPRIVATE="" GOINSECURE=""
# What changes the code Go makes, set rather than inherited.
export CGO_ENABLED=0 GOAMD64=v1 GOARM64=v8.0 GOEXPERIMENT="" GODEBUG=""

if [[ ! -d "$SRC/.git" ]]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$XRAY_TAG" "$XRAY_REPOSITORY" "$SRC"
fi
git -C "$SRC" fetch --quiet --depth 1 origin "refs/tags/$XRAY_TAG:refs/tags/$XRAY_TAG" 2>/dev/null || true
git -C "$SRC" -c advice.detachedHead=false checkout --quiet --force "$XRAY_TAG"
HEAD_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
[[ "$HEAD_COMMIT" == "$XRAY_COMMIT" ]] \
  || { echo "error: Xray's tag $XRAY_TAG now names $HEAD_COMMIT, not the pinned $XRAY_COMMIT: refused" >&2; exit 1; }
git -C "$SRC" diff --quiet HEAD || { echo "error: the Xray source in $SRC was changed: run $0 --clean" >&2; exit 1; }
# The upstream tag still requires affected network and compression libraries. Only the
# module versions and their verified checksums are patched; --record pins the resulting binaries.
git -C "$SRC" apply --unidiff-zero "$PWD/scripts/xray-modules.patch"

go_version="$(cd "$SRC" && go env GOVERSION)"
[[ "$go_version" == "go$GO_VERSION" ]] || { echo "error: Go is $go_version, not the pinned go$GO_VERSION" >&2; exit 1; }
(cd "$SRC" && go mod download && go mod verify >/dev/null) || { echo "error: Xray's modules do not verify against its go.sum" >&2; exit 1; }

build_one() {
  local goos="$1" arch="$2" out="$3"
  mkdir -p "$(dirname "$out")"
  (cd "$SRC" && GOOS="$goos" GOARCH="$arch" go build -trimpath -buildvcs=false \
    -ldflags "-s -w -buildid= -X github.com/xtls/xray-core/core.build=${XRAY_COMMIT:0:7}" \
    -o "$out" ./main)
  sha256 "$out"
}

if [[ "$CHECK_NOTICES" == "1" ]]; then
  [[ -n "$OUT" && -f "$OUT" ]] || { echo "error: --check-notices needs --out <a build of this pin>" >&2; exit 1; }
  scripts/xray_notices.py --source "$SRC" --binary "$OUT" --lock "$LOCK" --out "$NOTICE" --check
  exit 0
fi

if [[ "$RECORD" == "1" ]]; then
  for arch in arm64 amd64; do
    sum="$(build_one darwin "$arch" "$BUILD_ROOT/out/xray-darwin-$arch")"
    echo "SHA256_darwin_$arch=$sum"
  done
  scripts/xray_notices.py --source "$SRC" --binary "$BUILD_ROOT/out/xray-darwin-arm64" --lock "$LOCK" --out "$NOTICE"
  echo "Wrote $NOTICE; put the SHA-256 lines above into $LOCK"
  exit 0
fi

[[ -n "$ARCH" ]] || ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ARCH=arm64 ;;
  amd64|x86_64) ARCH=amd64 ;;
  *) echo "error: no Xray build for the architecture $ARCH" >&2; exit 1 ;;
esac
[[ -n "$OUT" ]] || OUT="$PWD/build/xray/xray-$GOOS_TARGET-$ARCH"
[[ "$OUT" == /* ]] || OUT="$PWD/$OUT"
sum="$(build_one "$GOOS_TARGET" "$ARCH" "$OUT")"
echo "Built $OUT (Xray $XRAY_TAG, $GOOS_TARGET/$ARCH, go$GO_VERSION): SHA-256 $sum, $(wc -c < "$OUT" | tr -d ' ') bytes"
if [[ "$CHECK" == "1" ]]; then
  key="SHA256_${GOOS_TARGET}_${ARCH}"
  expected="${!key:-}"
  [[ -n "$expected" && "$expected" != "PENDING" ]] || { echo "error: $LOCK records no $key" >&2; exit 1; }
  if [[ "$sum" != "$expected" ]]; then
    rm -f "$OUT"
    echo "error: this build of Xray is $sum, and $LOCK records $expected: not the reproducible build, refused" >&2
    exit 1
  fi
  echo "The SHA-256 is the one $LOCK records: the same bytes as every other build of this pin"
fi
