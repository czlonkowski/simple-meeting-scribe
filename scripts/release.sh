#!/bin/bash
# Build and verify a DMG. Never installs or launches the app.
set -euo pipefail
usage() {
    cat <<'HELP'
Usage: scripts/release.sh VERSION BUILD_NUMBER [--unsigned]

Signed release (default):
  SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
  NOTARY_PROFILE='meeting-transcriber-notary'

--unsigned builds a local packaging test only; GitHub upload rejects it.
Optional: BUILD_JOBS (default 2), LAME_SOURCE_ARCHIVE (verified local source),
          RELEASE_PACKAGES_DIR (isolated Swift package cache to reuse).
See docs/releases.md for certificate setup and GitHub draft upload.
HELP
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
VERSION="$1"
BUILD_NUMBER="$2"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $BUILD_NUMBER =~ ^[1-9][0-9]*$ ]] || {
    echo "Use a numeric VERSION (e.g. 0.1.0) and positive BUILD_NUMBER." >&2; exit 2;
}
UNSIGNED=false
if [[ $# -eq 3 ]]; then
    [[ $3 == --unsigned ]] || { usage >&2; exit 2; }
    UNSIGNED=true
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[[ $(uname -m) == arm64 ]] || { echo "Build on Apple Silicon." >&2; exit 1; }
for tool in xcodegen xcodebuild xcrun python3 pkg-config; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
COMMIT="$(git rev-parse HEAD)"
DIRTY=false
[[ -z $(git status --porcelain) ]] || DIRTY=true
if [[ $UNSIGNED == false ]]; then
    [[ ${SIGNING_IDENTITY:-} == 'Developer ID Application: '* ]] || {
        echo "Set SIGNING_IDENTITY to your Developer ID Application identity." >&2; exit 1;
    }
    [[ -n ${NOTARY_PROFILE:-} ]] || { echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2; exit 1; }
    [[ $DIRTY == false ]] || { echo "Build signed releases from a clean, committed checkout (including untracked files)." >&2; exit 1; }
    security find-identity -v -p codesigning | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null || {
        echo "Signing identity/private key is unavailable." >&2; exit 1;
    }
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null
fi
NAME="Simple-Meeting-Scribe-$VERSION-arm64"
[[ $UNSIGNED == false ]] || NAME="$NAME-UNSIGNED"
OUTPUT="$REPO_ROOT/dist/$NAME-build$BUILD_NUMBER"
[[ ! -e $OUTPUT ]] || { echo "Output already exists: $OUTPUT" >&2; exit 1; }
mkdir -p "$REPO_ROOT/build" "$REPO_ROOT/dist"
WORK="$(mktemp -d "$REPO_ROOT/build/release.XXXXXX")"
echo "Release work directory: $WORK"
MOUNT=""
cleanup() {
    if [[ -n $MOUNT ]]; then hdiutil detach "$MOUNT" >/dev/null || true; fi
}
trap cleanup EXIT
mkdir -p "$WORK/source" "$WORK/artifacts" "$WORK/image"
if [[ $UNSIGNED == false ]]; then
    git archive HEAD | tar -x -C "$WORK/source"
else
    # Copy only build inputs, including current edits, for local verification.
    tar -cf - MeetingTranscriber MeetingTranscriberTests scripts project.yml LICENSE | tar -xf - -C "$WORK/source"
fi
SOURCE="$WORK/source"
PACKAGES="${RELEASE_PACKAGES_DIR:-$WORK/SourcePackages}"
mkdir -p "$PACKAGES"
PACKAGES="$(cd "$PACKAGES" && pwd)"
cd "$SOURCE"
xcodegen generate
mkdir -p MeetingTranscriber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp scripts/release/Package.resolved MeetingTranscriber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
swift scripts/generate_app_icon.swift > "$WORK/icons.log" 2>&1
echo "Building Release (log: $WORK/xcodebuild.log)…"
if ! xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber \
    -configuration Release -destination 'generic/platform=macOS' -skipMacroValidation \
    -derivedDataPath "$WORK/DerivedData" -clonedSourcePackagesDirPath "$PACKAGES" \
    -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
    -jobs "${BUILD_JOBS:-2}" CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build > "$WORK/xcodebuild.log" 2>&1; then
    tail -80 "$WORK/xcodebuild.log" >&2
    exit 1
fi
scripts/build-lame.sh "$WORK/lame"
APP="$WORK/image/MeetingTranscriber.app"
ditto "$WORK/DerivedData/Build/Products/Release/MeetingTranscriber.app" "$APP"
python3 scripts/release/bundle.py prepare "$APP" "$PACKAGES" "$WORK/lame"
python3 scripts/release/bundle.py verify "$APP"
scripts/test-audio-export.sh "$APP/Contents/Helpers/lame" > "$WORK/audio-export-tests.log" 2>&1 || {
    cat "$WORK/audio-export-tests.log" >&2; exit 1;
}

notarize() {
    local input="$1" label="$2" result="$WORK/$2-notary.json"
    xcrun notarytool submit "$input" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result"
    if ! python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("status") != "Accepted")' "$result"; then
        echo "Notarization was not accepted; see $result. Use notarytool log with the submission ID." >&2
        return 1
    fi
    xcrun stapler staple "$3"
    xcrun stapler validate "$3"
}
if [[ $UNSIGNED == false ]]; then
    python3 scripts/release/bundle.py sign "$APP" "$SIGNING_IDENTITY"
    python3 scripts/release/bundle.py verify "$APP" --signed
    ditto -c -k --keepParent "$APP" "$WORK/notarization.zip"
    notarize "$WORK/notarization.zip" app "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
ln -s /Applications "$WORK/image/Applications"
cat > "$WORK/image/Read Me.txt" <<'README'
Simple Meeting Scribe — Apple Silicon, macOS 26 or later

Drag MeetingTranscriber into Applications, then open it from Applications.
Allow microphone, screen/system audio recording, and browser Automation when prompted.
Local speech/summary models download on first use and need internet and free disk space.
MP3 export includes its encoder. Xcode and Homebrew are not needed.
Optional Azure features require your own configuration and credentials.

Source, documentation and releases:
https://github.com/czlonkowski/simple-meeting-scribe

Third-party licenses and the complete LAME source are inside the app:
Show Package Contents → Contents/Resources/ThirdParty
README
DMG="$WORK/artifacts/$NAME.dmg"
hdiutil create -volname "Simple Meeting Scribe $VERSION" -srcfolder "$WORK/image" \
    -format UDZO -fs HFS+ "$DMG"
if [[ $UNSIGNED == false ]]; then
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
    notarize "$DMG" dmg "$DMG"
    codesign --verify --verbose=2 "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
hdiutil verify "$DMG"
MOUNT="$WORK/mounted"
mkdir "$MOUNT"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
if [[ $UNSIGNED == true ]]; then
    python3 scripts/release/bundle.py verify "$MOUNT/MeetingTranscriber.app"
else
    python3 scripts/release/bundle.py verify "$MOUNT/MeetingTranscriber.app" --signed
fi
if [[ $UNSIGNED == false ]]; then
    xcrun stapler validate "$MOUNT/MeetingTranscriber.app"
    spctl --assess --type execute --verbose=2 "$MOUNT/MeetingTranscriber.app"
fi
hdiutil detach "$MOUNT" >/dev/null
MOUNT=""
python3 - "$WORK/artifacts" "$VERSION" "$BUILD_NUMBER" "$COMMIT" "$DIRTY" "$UNSIGNED" "$DMG" <<'PY'
import hashlib, json, pathlib, subprocess, sys
output, version, build, commit, dirty, unsigned, dmg = sys.argv[1:]
path = pathlib.Path(dmg)
digest = hashlib.sha256(path.read_bytes()).hexdigest()
manifest = dict(schemaVersion=1, version=version, buildNumber=build, commit=commit,
                sourceDirty=dirty == "true", signed=unsigned == "false", notarized=unsigned == "false",
                architecture="arm64", minimumMacOS="26.0", dmg=path.name, sha256=digest,
                xcode=subprocess.check_output(["xcodebuild", "-version"], text=True).strip())
pathlib.Path(output, "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
pathlib.Path(output, "SHA256SUMS").write_text(f"{digest}  {path.name}\n")
PY
mv "$WORK/artifacts" "$OUTPUT"
echo "Verified artifacts: $OUTPUT"
if [[ $UNSIGNED == true ]]; then
    echo "UNSIGNED local verification only. This DMG cannot be uploaded by github-release.sh."
else
    echo "Next: scripts/github-release.sh '$OUTPUT' /path/to/release-notes.md"
fi
