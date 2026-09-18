#!/bin/bash
# Run the real exporter XCTest source without launching the application or using
# recording devices. Pass the packaged encoder to test release MP3 output.
# Usage: scripts/test-audio-export.sh [/path/to/lame]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -le 1 ]] || { echo "Usage: $0 [/path/to/lame]" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/meeting-export-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/MeetingTranscriber" "$WORK/Tests/MeetingTranscriberTests"
cp "$REPO_ROOT/MeetingTranscriber/Storage/MixedAudioExporter.swift" "$WORK/Sources/MeetingTranscriber/"
cp "$REPO_ROOT/MeetingTranscriberTests/MixedAudioExporterTests.swift" "$WORK/Tests/MeetingTranscriberTests/"
cat > "$WORK/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "AudioExportVerification",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MeetingTranscriber"),
        .testTarget(name: "MeetingTranscriberTests", dependencies: ["MeetingTranscriber"])
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
if [[ $# -eq 1 ]]; then
    [[ -x $1 ]] || { echo "Encoder is not executable: $1" >&2; exit 1; }
    export TEST_LAME_EXECUTABLE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi
swift test --package-path "$WORK" --scratch-path "$WORK/.build" --jobs "${BUILD_JOBS:-2}"
