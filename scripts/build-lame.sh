#!/bin/bash
# Build an arm64, encoder-only LAME with no Homebrew runtime dependencies.
# Usage: scripts/build-lame.sh OUTPUT_DIRECTORY
# Optional: LAME_SOURCE_ARCHIVE=/path/to/archive (still checksum verified).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/release/lame.env"
[[ $# -eq 1 ]] || { echo "Usage: $0 OUTPUT_DIRECTORY" >&2; exit 2; }
[[ $(uname -m) == arm64 ]] || { echo "Build on an Apple Silicon Mac." >&2; exit 1; }
command -v pkg-config >/dev/null || { echo "Missing build tool: pkgconf (pkg-config)." >&2; exit 1; }
[[ ! -e $1 ]] || { echo "Output already exists: $1" >&2; exit 1; }
mkdir -p "$1"
OUTPUT="$(cd "$1" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meeting-lame.XXXXXX")"
cleanup() {
    local status=$?
    [[ ! -f "$WORK/lame-$LAME_VERSION/config.log" ]] || cp "$WORK/lame-$LAME_VERSION/config.log" "$OUTPUT/config.log"
    if [[ $status -ne 0 ]]; then
        echo "LAME build failed; logs are in $OUTPUT" >&2
        if [[ -f "$OUTPUT/build.log" ]]; then tail -25 "$OUTPUT/build.log" >&2; fi
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
ARCHIVE="$OUTPUT/lame-$LAME_VERSION.tar.gz"
if [[ -n ${LAME_SOURCE_ARCHIVE:-} ]]; then
    cp "$LAME_SOURCE_ARCHIVE" "$ARCHIVE"
else
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 "$LAME_URL" -o "$ARCHIVE"
fi
[[ $(shasum -a 256 "$ARCHIVE" | awk '{print $1}') == "$LAME_SHA256" ]] || {
    echo "LAME source checksum mismatch." >&2; exit 1;
}
tar -xzf "$ARCHIVE" -C "$WORK"
cd "$WORK/lame-$LAME_VERSION"
echo "Building LAME $LAME_VERSION (logs: $OUTPUT)…"
# C17 supports LAME's legacy declarations. parse.c needs locale.h even when
# configure rejects Apple's iconv implementation; force the missing include
# without changing upstream sources. Decoder/libsndfile are unnecessary for WAV.
env SDKROOT="$(xcrun --show-sdk-path)" CC="$(xcrun --find clang)" CFLAGS="-O2 -arch arm64 -mmacosx-version-min=26.0 -std=gnu17 -Wno-implicit-function-declaration -include locale.h" \
    LDFLAGS="-arch arm64 -mmacosx-version-min=26.0" \
    ./configure --prefix="$WORK/install" --disable-shared --enable-static \
    --disable-decoder --disable-analyzer-hooks --disable-cpml --disable-nasm \
    --disable-gtktest --without-libiconv-prefix \
    --with-fileio=lame > "$OUTPUT/configure.log" 2>&1
env SDKROOT="$(xcrun --show-sdk-path)" make -j "${BUILD_JOBS:-2}" > "$OUTPUT/build.log" 2>&1
cp frontend/lame "$OUTPUT/lame"
chmod 755 "$OUTPUT/lame"
cp COPYING LICENSE "$OUTPUT/"
cp "$REPO_ROOT/scripts/build-lame.sh" "$OUTPUT/build-lame.sh"
cp "$REPO_ROOT/scripts/release/lame.env" "$OUTPUT/lame.env"
[[ $(lipo -archs "$OUTPUT/lame") == arm64 ]] || { echo "Wrong encoder architecture." >&2; exit 1; }
otool -L "$OUTPUT/lame" | tail -n +2 | while IFS= read -r dependency; do
    case "$dependency" in
        *'/usr/lib/'*|*'/System/Library/'*) ;;
        *) echo "Non-system encoder dependency: $dependency" >&2; exit 1 ;;
    esac
done
"$OUTPUT/lame" --version
echo "Built encoder: $OUTPUT/lame"
