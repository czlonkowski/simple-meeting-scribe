#!/bin/bash
# Build Debug, swap /Applications/MeetingTranscriber.app, re-register with
# Launch Services. Single admin prompt at the end via osascript.
#
# Usage:
#   scripts/reinstall.sh              # build, install, relaunch
#   scripts/reinstall.sh --no-build   # skip build (use existing Debug bundle)
#   scripts/reinstall.sh --no-launch  # don't relaunch after install
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

BUILD=1
LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --no-build)  BUILD=0 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help)
      sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Locate the freshest Debug build. The DerivedData hash is stable per-user but
# resolve it dynamically so the script survives an Xcode reset.
find_app() {
  ls -dt ~/Library/Developer/Xcode/DerivedData/MeetingTranscriber-*/Build/Products/Debug/MeetingTranscriber.app 2>/dev/null | head -n 1
}

if [[ $BUILD -eq 1 ]]; then
  echo "→ Building Debug…"
  xcodebuild \
    -project MeetingTranscriber.xcodeproj \
    -scheme MeetingTranscriber \
    -configuration Debug \
    -destination 'platform=macOS' \
    -quiet \
    build
fi

APP_SRC="$(find_app)"
if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "✗ Could not find Debug bundle in DerivedData." >&2
  echo "  Run without --no-build, or open the project in Xcode once." >&2
  exit 1
fi

echo "→ Quitting running instance (if any)…"
pkill -x MeetingTranscriber 2>/dev/null || true
sleep 0.3

echo "→ Installing into /Applications (admin prompt)…"
osascript -e "do shell script \"rm -rf /Applications/MeetingTranscriber.app && cp -R '$APP_SRC' /Applications/ && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MeetingTranscriber.app\" with administrator privileges"

if [[ $LAUNCH -eq 1 ]]; then
  echo "→ Launching…"
  open -a /Applications/MeetingTranscriber.app
fi

echo "✓ Done."
