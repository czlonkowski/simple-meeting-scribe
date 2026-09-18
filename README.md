# Simple Meeting Scribe

A personal, 100% local meeting transcriber for macOS. I built it for myself.
I'm putting the source out there because other people asked — **not** because
I'm trying to ship a product.

There is no support commitment or roadmap. If something
breaks, you fix it. If you want a feature, you add it. The project is MIT
licensed; fork it, strip it, reshape it — it's yours.

---

## What it does

- Detects when a Google Meet / Zoom / Teams / Whereby call opens in Arc,
  Safari, or Chrome and offers to start recording.
- Records your microphone **and** the system audio of the meeting as two
  separate tracks (so the transcript can label "You" vs "Remote").
- Transcribes both tracks with [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper Large v3 / v3 Turbo, CoreML / ANE).
- Diarizes the remote track with [FluidAudio](https://github.com/FluidInference/FluidAudio)
  (Pyannote on CoreML) so multiple remote speakers get distinct labels.
- Saves `.md` + `.json` transcripts to `~/Documents/MeetingTranscripts/`.
- Optional on-device LLM summarization + action items + auto-titles via
  [MLX](https://github.com/ml-explore/mlx-swift-lm) — Bielik for Polish,
  Qwen3.5 for English — or with your own Azure OpenAI deployments
  (Settings → Summary → Azure OpenAI deployments), pickable per meeting.
- Drag any `.mp4` / `.m4a` / `.mov` / `.wav` / `.mp3` onto the window to
  transcribe an existing recording.

## What it does not do

- No telemetry or required app account. Local models download from Hugging Face;
  optional Azure transcription/summarization uses your own credentials.
- No auto-update. No App Store listing.
- No CI or backwards-compatibility promise.
- Not localised beyond English + Polish (the two languages I need).

Local processing happens on your machine. If the network is off, models already
downloaded keep working. Optional Azure features require a network connection.

## Download the app

Check [GitHub Releases](https://github.com/czlonkowski/simple-meeting-scribe/releases)
for a signed, notarized `Simple-Meeting-Scribe-<version>-arm64.dmg`. If a release
does not have a DMG yet, use the source build instructions below.

1. Open the DMG and drag **MeetingTranscriber** into **Applications**.
2. Open it from Applications and approve recording/Automation permissions when prompted.
3. Download the local models you want to use. Initial downloads need internet access.

The DMG includes the MP3 encoder; **Xcode and Homebrew are not required**.
You need an **Apple Silicon Mac and macOS 26 or later**, plus space for models.
To update, quit the app when you are not recording and replace it with the newer
download. Maintainers: see [the release guide](docs/releases.md).

## Requirements

- Apple Silicon Mac (M1 or newer; M3+ strongly recommended for the 11B
  Polish model). Intel is not supported — MLX and WhisperKit both assume
  Apple Silicon.
- macOS 26 Tahoe. The UI uses Liquid Glass, `@Observable`, and other
  macOS 26 APIs. Older macOS will not build.
- For source builds: Xcode 26+ and the Xcode Metal Toolchain (Xcode will prompt on first build,
  or you can pre-install with `xcodebuild -downloadComponent MetalToolchain`).
- For source builds: [xcodegen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.
- For source builds: [LAME](https://lame.sourceforge.io/) — `brew install lame` (used only when
  exporting a mixed meeting recording as MP3).
- ~15 GB free disk space if you want to cache all the optional models.
- 32 GB RAM recommended for the larger LLMs (Qwen3.5-9B, Bielik-11B). 16 GB
  works for Qwen3.5-4B and the smaller Bielik variant.

## Build from source

```bash
git clone https://github.com/czlonkowski/simple-meeting-scribe
cd simple-meeting-scribe
xcodegen generate
xcodebuild -project MeetingTranscriber.xcodeproj \
           -scheme MeetingTranscriber \
           -configuration Debug \
           -destination 'platform=macOS' \
           -skipMacroValidation \
           CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM='' \
           build
```

Run the app from `~/Library/Developer/Xcode/DerivedData/.../Debug/MeetingTranscriber.app`,
or copy it into `/Applications` with `sudo cp -R …`.

## …or let an AI coding agent install it for you

If you already use [Claude Code](https://claude.com/claude-code), Codex, or a
similar coding agent, paste this prompt into it and let it do the work. You'll
still need to approve Xcode / Homebrew / sudo prompts as they come up.

> ```
> Please install Simple Meeting Scribe on this Mac. It's a SwiftUI app
> at https://github.com/czlonkowski/simple-meeting-scribe. Do this end
> to end:
>
> 1. Verify prerequisites: Apple Silicon, macOS 26 or newer, Xcode 26+
>    installed. If Xcode Command Line Tools aren't installed, run
>    `xcode-select --install` and wait for it to finish.
> 2. Install xcodegen and LAME if missing: `brew install xcodegen lame` (install
>    Homebrew first with the official script if it's not there).
> 3. Pre-download the Metal Toolchain so the build doesn't stall on it:
>    `xcodebuild -downloadComponent MetalToolchain`
> 4. Clone the repo into ~/Developer (create the directory if needed)
>    and `cd` into it:
>    `git clone https://github.com/czlonkowski/simple-meeting-scribe
>    ~/Developer/simple-meeting-scribe && cd ~/Developer/simple-meeting-scribe`
> 5. Generate the Xcode project: `xcodegen generate`
> 6. Build Release:
>    `xcodebuild -project MeetingTranscriber.xcodeproj
>    -scheme MeetingTranscriber -configuration Release
>    -destination 'platform=macOS' -skipMacroValidation
>    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=''
>    -derivedDataPath build build`
> 7. Install to /Applications (this needs sudo — ask me to run it if you
>    can't):
>    `sudo rm -rf /Applications/MeetingTranscriber.app &&
>     sudo cp -R build/Build/Products/Release/MeetingTranscriber.app
>     /Applications/ &&
>     sudo /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
>     -f /Applications/MeetingTranscriber.app`
> 8. Open the app from /Applications once so macOS can register it, then
>    tell me:
>    - to grant Microphone + Screen Recording when prompted,
>    - to approve Automation access for Arc / Safari / Chrome on first
>      meeting detection,
>    - to open Settings → Summary → Model Library and download a model
>      before the first summarize (Qwen3.5-4B 8-bit for English,
>      Bielik-11B v3 for Polish are the defaults).
>
> If any step fails, stop and show me the exact error — don't paper
> over it. If a step asks for sudo, run it only once and with my
> permission.
> ```

> **Why `-skipMacroValidation`?** MLX Swift LM ships compiler-plugin macros
> (`#hubDownloader`, `#huggingFaceTokenizerLoader`). Xcode prompts to trust
> them on first use. The CLI flag skips that prompt. In Xcode GUI, click
> "Trust & Enable" on first build instead.

The source-build commands above use ad-hoc signing. Rebuilding or moving that
app can require granting Microphone, Screen Recording and Automation again.
Published DMGs use a stable Developer ID signature.

## First run

1. Launch. The dock icon is generated by `scripts/generate_app_icon.swift` —
   regenerate any time with `swift scripts/generate_app_icon.swift`.
2. Start a recording once; macOS will pop prompts for **Microphone** and
   **Screen Recording**. Approve both.
3. Open a meeting URL in Arc/Safari/Chrome. macOS will pop an **Automation**
   prompt for each browser the first time the app queries it.
4. Settings → **Summary** → Model Library → pick a model, click Download.
   Models live under `~/Documents/huggingface/models/`.

## Files on disk

- `~/Documents/MeetingTranscripts/` — transcripts (`.md` + `.json`).
- `~/Documents/MeetingTranscripts/recordings/` — the paired `.voice.wav`
  and `.system.wav` files for each session.
- `~/Documents/huggingface/models/` — downloaded LLM weights.
- Whisper models live under WhisperKit's own cache (first download shows
  progress inside the app).

Deleting a transcript from the sidebar (right-click → Delete) removes all
of the above for that session.

## Repo layout

```
MeetingTranscriber/
├── App/             # SwiftUI @main + AppState + menu-bar extra
├── Capture/         # AudioRecorder, SystemAudioCapture (SCStream), MeetingDetector
├── Transcribe/      # WhisperEngine, DiarizationEngine, TranscriptionPipeline
├── Summarize/       # MLX wrapper, per-language prompts, model enum
├── Storage/         # TranscriptStore, DictionaryStore, SummaryStore
├── UI/              # SwiftUI views
└── Resources/       # Info.plist, entitlements, meeting-patterns.json
```

`project.yml` drives everything — edit the YAML, run `xcodegen generate`,
never touch the `.xcodeproj` by hand.

## Contributions

I'm not taking pull requests. If you want to add something, fork it.
Issues are welcome as a place to discuss, but I make no promise to
respond.

## License

MIT — see [LICENSE](LICENSE).
