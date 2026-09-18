# GitHub Releases

Distribution is a Developer ID signed, Apple-notarized DMG for **Apple Silicon and
macOS 26 or later**. Release tools build in `build/`, write final artifacts to
`dist/`, and never install, launch, quit, or replace the application. Uploading
creates a **draft** release; publication is a separate action in GitHub.

## One-time setup on the release Mac

1. Use an active paid Apple Developer Program membership. In **Xcode → Settings →
   Accounts → your team → Manage Certificates**, create a **Developer ID
   Application** certificate. An Apple Development or Apple Distribution
   certificate is not the certificate for this workflow. The matching private
   key must be in the Mac's keychain. A Developer ID Installer certificate is not
   needed for a drag-and-drop DMG.
2. Install build tools: Xcode (verified with **26.5**), its Metal Toolchain,
   XcodeGen, Python 3.9+, `pkgconf`, and GitHub CLI. With Homebrew:

   ```sh
   brew install xcodegen pkgconf gh
   xcodebuild -downloadComponent MetalToolchain
   ```

   These are **maintainer tools**. End users need none of them.
3. Save notarization credentials in a local keychain profile using either method
   below. Do not put passwords or private keys in the repository.

   **App-specific password:** generate one at **account.apple.com → Sign-In and
   Security → App-Specific Passwords**, then supply it, the Apple ID, and team ID
   when prompted:

   ```sh
   xcrun notarytool store-credentials meeting-transcriber-notary
   ```

   **App Store Connect API key:** in **Users and Access → Integrations → App Store
   Connect API → Team Keys**, create a dedicated key with the **Developer** role.
   Download its `.p8` file to a private location outside the repository. Copy the
   Key ID and Issuer ID from that page, then run:

   ```sh
   xcrun notarytool store-credentials meeting-transcriber-notary \
     --key /private/path/AuthKey_KEY_ID.p8 \
     --key-id KEY_ID \
     --issuer ISSUER_ID
   ```

   This method does not require an app-specific password. `notarytool` validates
   the credentials before storing them. Both methods use the same `NOTARY_PROFILE`
   setting below; the release scripts do not need the password or key file path.

4. Find the exact signing identity and authenticate GitHub CLI:

   ```sh
   security find-identity -v -p codesigning
   gh auth login
   ```

## Build a release

Use a clean, committed checkout (a dedicated worktree is convenient). Untracked
files also make a checkout dirty. Do not include recordings, model weights,
transcripts, or credentials in a release commit.

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='meeting-transcriber-notary'
scripts/release.sh 0.1.0 1
```

The first argument sets the version; the second is a positive build number.
Both are embedded in `Info.plist`. Increment the version for each GitHub Release
and increment the build number for each distribution build. Existing artifact
directories are never overwritten.

The command:

1. Checks signing identity, notarization credentials, and clean source state.
2. Takes a source snapshot, regenerates the Xcode project, generates icons, and
   builds **Release/arm64** with the committed Swift package lockfile. It defaults
   to two build jobs; use `BUILD_JOBS` to change this.
3. Builds checksum-pinned LAME 4.0 from unmodified upstream source with a static
   encoder and no external decoder dependency. The app prefers
   `Contents/Helpers/lame`; Homebrew is only a fallback for development builds.
4. Bundles license notices, the complete LAME source archive and build recipe,
   and dependency versions. It checks package revisions against the lockfile.
5. Verifies architecture, resources (including the MLX Metal library), absence
   of debug/test payloads, and portable dynamic-library paths. Runs the exporter
   XCTest suite against the exact packaged encoder using synthetic WAV files.
6. Signs nested code inside-out, then signs the app with Hardened Runtime and a
   secure timestamp. Rejects development signatures and `get-task-allow`.
7. Notarizes and staples the app, creates and signs the DMG, then notarizes and
   staples the DMG. Both have tickets so a copied app can pass Gatekeeper offline.
8. Mounts the DMG read-only without opening Finder or the app, verifies its
   contents, and writes the DMG, `SHA256SUMS`, and `release.json` to `dist/`.

Build and notarization logs stay in the printed `build/release.*` directory. If
notarization is rejected, use its submission ID with `xcrun notarytool log ID
--keychain-profile meeting-transcriber-notary` and fix the issue before rebuilding.
No release artifacts are promoted to `dist/` on failure. Never upload work files
or an `UNSIGNED` package.

### Verify packaging before certificates are ready

```sh
scripts/release.sh 0.1.0 1 --unsigned
```

This exercises the build, encoder tests, and DMG round trip. It does **not** prove
Developer ID signing, notarization, or Gatekeeper acceptance. Its filename and
manifest mark it `UNSIGNED`; the GitHub upload command rejects it.

For repeated builds, `RELEASE_PACKAGES_DIR=/absolute/path/to/dedicated-cache`
reuses package checkouts. Keep this separate from the running app's development
cache. `LAME_SOURCE_ARCHIVE=/absolute/path/to/lame-4.0.tar.gz` avoids another
source download; the SHA-256 check still applies.

### Update dependencies deliberately

`scripts/release/Package.resolved` pins release dependencies. To update it, resolve
and test packages in Xcode, copy the generated
`MeetingTranscriber.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
over the committed lockfile, and commit it. Release builds refuse automatic
version changes. The LAME URL/version/hash live in `scripts/release/lame.env`.

## Upload a draft GitHub Release

Push the exact built commit and an annotated version tag to the repository first.
Create the tag on the commit recorded in `release.json`, not on later edits:

```sh
git tag -a v0.1.0 <built-commit> -m 'Simple Meeting Scribe 0.1.0'
git push origin v0.1.0
scripts/github-release.sh \
  dist/Simple-Meeting-Scribe-0.1.0-arm64-build1 \
  /path/to/release-notes.md
```

The uploader is fixed to `czlonkowski/simple-meeting-scribe`. It checks checksums,
the DMG signature, stapled ticket and Gatekeeper verdict, and that the remote tag
resolves to the recorded commit. It refuses unsigned/dirty builds, missing tags,
tag mismatches, and replacement of existing releases. It uploads only the DMG,
checksum file, and manifest. Source archives are supplied by GitHub from the tag;
LAME source also travels inside the app itself.

## Check before publishing the draft

On a clean Apple Silicon Mac/user account with macOS 26, **download the draft
asset through a browser** to exercise quarantine/Gatekeeper. Drag the app to
Applications and check:

- Ordinary launch with no unidentified-developer workaround.
- First-run microphone and screen/system audio permissions; browser Automation
  permission and meeting detection.
- Initial model download, file import, transcription, and local summarization.
- Mixed MP3 export **without Homebrew installed**.
- Offline launch after downloading models; no bundled Metal/resource failures.

Verify without changing permissions or bypassing quarantine:

```sh
xcrun stapler validate /Applications/MeetingTranscriber.app
spctl --assess --type execute --verbose=2 /Applications/MeetingTranscriber.app
```

Then publish the draft in GitHub's release editor. There is no automatic updater;
users download a later DMG and replace the app when they are not recording.

## Focused checks that do not launch the app

```sh
scripts/test-audio-export.sh /path/to/built/lame
python3 -m unittest discover -s scripts/release -p 'test_*.py' -v
bash -n scripts/release.sh scripts/github-release.sh scripts/build-lame.sh scripts/test-audio-export.sh
```

The regular Xcode XCTest scheme hosts tests inside the application. Run that
suite when no active recording/meeting could be affected. The isolated exporter
test command above has no application host and does not use audio devices.
