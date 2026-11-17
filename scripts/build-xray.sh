#!/usr/bin/env bash
# Builds Xray-core from its pinned source (scripts/xray.lock) for macOS, reproducibly, and checks the
# result against the SHA-256 recorded there (docs/TUNNEL.md, "Links").
#
#   scripts/build-xray.sh --arch arm64 --out build/xray/xray-darwin-arm64
#   scripts/build-xray.sh --arch amd64 --out …          # Intel
#   scripts/build-xray.sh --record                      # both architectures; prints the SHA-256 lines and
#                                                       # writes Resources/Xray/NOTICE.txt anew (after a pin change)
#   scripts/build-xray.sh --goos linux --arch amd64 --out … --no-check   # a Linux build, for testing configurations
#
# What makes the bytes the same on every host: the source at the pinned commit (refused if the tag now
# names another), its modules as its go.sum names them (`go mod verify`), the pinned Go toolchain
# (GOTOOLCHAIN: Go fetches it and checks it against its checksum database), CGO off, -trimpath, no VCS
# stamp, an empty build id, and every variable that changes code generation set explicitly. Nothing is
# downloaded but the source, its modules and the toolchain, all checked; no binary from anywhere.
#
# Needs: git, and a `go` command of version 1.21 or later (it fetches the pinned one). On a Mac without
# Go: `brew install go`, or CI's setup-go. Leaves nothing outside its work folder (BUILD_ROOT, default
# build/xray-src), which `--clean` removes, with its module and build caches.
set -euo pipefail

cd "$(dirname "$0")/.."
LOCK=scripts/xray.lock
NOTICE=Resources/Xray/NOTICE.txt
# shellcheck disable=SC1090
source <(grep -E '^[A-Za-z0-9_]+=' "$LOCK")

ARCH=""
GOOS_TARGET=darwin
OUT=""
CHECK=1
RECORD=0
CLEAN=0
BUILD_ROOT="${BUILD_ROOT:-$PWD/build/xray-src}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --goos) GOOS_TARGET="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-check) CHECK=0; shift ;;
    --record) RECORD=1; shift ;;
    --clean) CLEAN=1; shift ;;
    *) echo "usage: $0 [--arch arm64|amd64] [--goos darwin|linux] [--out path] [--no-check] [--record] [--clean]" >&2; exit 64 ;;
  esac
done

if [[ "$CLEAN" == "1" ]]; then
  [[ -d "$BUILD_ROOT" ]] && chmod -R u+w "$BUILD_ROOT" 2>/dev/null || true
  rm -rf "$BUILD_ROOT"
  echo "Removed $BUILD_ROOT"
  exit 0
fi

command -v git >/dev/null || { echo "error: build-xray.sh needs git" >&2; exit 1; }
command -v go >/dev/null || { echo "error: build-xray.sh needs a go command (1.21 or later); it fetches Go $GO_VERSION itself" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# A work folder of its own: the source, Go's module cache and build cache, the toolchain Go fetches.
mkdir -p "$BUILD_ROOT"
SRC="$BUILD_ROOT/Xray-core"
export GOPATH="$BUILD_ROOT/gopath"
export GOMODCACHE="$BUILD_ROOT/gopath/pkg/mod"
export GOCACHE="$BUILD_ROOT/gocache"
export GOTOOLCHAIN="go$GO_VERSION"
export GOFLAGS="-mod=readonly -modcacherw"
export GOPROXY="${GOPROXY:-https://proxy.golang.org}"
export GOSUMDB="sum.golang.org"
export GONOSUMDB="" GOPRIVATE="" GOINSECURE=""
# What changes the code Go makes, set rather than inherited.
export CGO_ENABLED=0 GOAMD64=v1 GOARM64=v8.0 GOEXPERIMENT="" GODEBUG=""

if [[ ! -d "$SRC/.git" ]]; then
  git clone --quiet --depth 1 --branch "$XRAY_TAG" "$XRAY_REPOSITORY" "$SRC"
fi
git -C "$SRC" fetch --quiet --depth 1 origin "refs/tags/$XRAY_TAG:refs/tags/$XRAY_TAG" 2>/dev/null || true
git -C "$SRC" -c advice.detachedHead=false checkout --quiet --force "$XRAY_TAG"
HEAD_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
[[ "$HEAD_COMMIT" == "$XRAY_COMMIT" ]] \
  || { echo "error: Xray's tag $XRAY_TAG now names $HEAD_COMMIT, not the pinned $XRAY_COMMIT: refused" >&2; exit 1; }
git -C "$SRC" diff --quiet HEAD || { echo "error: the Xray source in $SRC was changed: run $0 --clean" >&2; exit 1; }

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
