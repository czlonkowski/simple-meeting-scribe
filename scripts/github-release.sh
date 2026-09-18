#!/bin/bash
# Upload only verified artifacts to a new DRAFT GitHub Release.
# Never creates/pushes tags, replaces assets, or publishes a release.
set -euo pipefail
if [[ $# -ne 2 || ${1:-} == --help ]]; then
    echo "Usage: scripts/github-release.sh ARTIFACT_DIRECTORY RELEASE_NOTES_FILE"
    [[ ${1:-} == --help ]] && exit 0
    exit 2
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$(cd "$1" && pwd)"
NOTES="$2"
REPOSITORY=czlonkowski/simple-meeting-scribe
[[ -s $NOTES ]] || { echo "Provide a nonempty release notes file." >&2; exit 1; }
METADATA="$(python3 "$REPO_ROOT/scripts/release/artifact.py" "$ARTIFACTS")"
IFS=$'\t' read -r VERSION COMMIT DMG_NAME <<< "$METADATA"
DMG="$ARTIFACTS/$DMG_NAME"
codesign --verify --verbose=2 "$DMG"
codesign -d --verbose=4 "$DMG" 2>&1 | grep -F 'Authority=Developer ID Application:' >/dev/null
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
gh auth status >/dev/null
TAG="v$VERSION"
gh api "repos/$REPOSITORY/git/ref/tags/$TAG" >/dev/null
REMOTE_COMMIT="$(gh api "repos/$REPOSITORY/commits/$TAG" --jq .sha)"
[[ $REMOTE_COMMIT == "$COMMIT" ]] || { echo "Remote tag $TAG does not match the built commit." >&2; exit 1; }
if gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "A release already exists for $TAG; refusing to replace assets." >&2
    exit 1
fi
gh release create "$TAG" --repo "$REPOSITORY" --verify-tag --draft \
    --title "Simple Meeting Scribe $VERSION" --notes-file "$NOTES" \
    "$DMG" "$ARTIFACTS/SHA256SUMS" "$ARTIFACTS/release.json"
echo "Draft created. Test the downloaded DMG on a clean Mac before publishing it on GitHub."
