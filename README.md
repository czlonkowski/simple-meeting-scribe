# Simple Meeting Scribe

A personal meeting transcriber for macOS. I built it for myself. I'm putting
the source out there because other people asked — **not** because I'm trying
to ship a product. Use the cloud when you want speed and quality, or keep
everything on your Mac when privacy matters most — you choose per meeting.

There is no support commitment or roadmap. If something breaks, you fix it.
If you want a feature, you add it. The project is MIT licensed; fork it, strip
it, reshape it — it's yours.

---

## What it does

**Record**
- Spots a Google Meet / Zoom / Teams / Whereby / Jitsi meeting open in Arc,
  Safari or Chrome and offers to record it.
- Records native calls on its own: WhatsApp, iPhone calls taken on the Mac,
  Signal, Telegram, and the Zoom, Teams and Slack apps. WhatsApp and iPhone
  recordings stop when you hang up.
- For other meetings, a "Meeting ended?" notification with a **Stop Recording**
  button appears when you leave the meeting or after 3 minutes of silence.
- Keeps your mic and the meeting audio as two tracks, so the transcript can tell
  "You" from the other side. Optionally records the meeting window as video.

**Transcribe**
- Cloud: Microsoft MAI-Transcribe-2 (Azure Speech, the default) or ElevenLabs
  Scribe v2, with your own keys.
- Local: Whisper Large v3 / v3 Turbo ([WhisperKit](https://github.com/argmaxinc/WhisperKit))
  or Parakeet v3 ([FluidAudio](https://github.com/FluidInference/FluidAudio)),
  with on-device speaker separation.
- Drag any `.mp4` / `.m4a` / `.mov` / `.wav` / `.mp3` onto the window to
  transcribe an existing recording.

**Summarize**
- Summary, action items and a title, on-device with
  [MLX](https://github.com/ml-explore/mlx-swift-lm) or with your own Azure
  OpenAI deployments. Pick the model per meeting.

**Library**
- Markdown + JSON transcripts, tags, a glossary of words to spell right, and
  named speakers. Export a meeting's mixed audio as MP3.
- A local [MCP server](docs/MCP.md) lets Claude Code or another MCP client on
  the same Mac search, read and tag your transcripts.

## Cloud or local

**Cloud — for speed and quality.** MAI-Transcribe-2 and ElevenLabs Scribe
transcribe an hour-long meeting in under a minute and gave the best accuracy
and speaker separation in my tests, Polish included. Azure OpenAI writes
summaries without loading a model on your Mac. You bring your own keys, so
the audio and text go to your own Azure or ElevenLabs account. If MAI fails
and an ElevenLabs key is set, the app retries with Scribe on its own.

**Local — when privacy matters most.** Whisper or Parakeet plus an MLX
summary model keep audio and text on your Mac and work offline once the
models are downloaded. It's slower and needs RAM for the summary model.

Mix them as you like: pick the engine and the summary model per meeting.
The setup assistant on first launch asks which you want as the default and
takes your keys; without a cloud key the app starts on local Whisper.

Either way there's no telemetry and no account. Keys stay in your Keychain.
Besides your chosen services, the app only downloads models from Hugging Face
and checks this repository's GitHub Releases for updates once a day (turn it
off in Settings → General → Updates).

## Install

1. Download `Simple-Meeting-Scribe-<version>-arm64.dmg` from
   [GitHub Releases](https://github.com/czlonkowski/simple-meeting-scribe/releases).
   It is signed and notarized by Apple.
2. Open the DMG and drag **MeetingTranscriber** into **Applications**.
3. Open it. A short setup assistant picks cloud or local transcription, the
   summary model, your meeting language and call recording, and asks for the
   permissions below. Rerun it any time from the app menu → Setup Assistant…

Updates are offered inside the app and install only when you click Install,
never during a recording. Maintainers: see [the release guide](docs/releases.md).

## Permissions

| Permission | Why |
| --- | --- |
| Microphone | Your side of the meeting |
| Screen & System Audio Recording | The meeting's audio, and window video if you turn it on |
| System Audio Recording Only | The other side of iPhone and FaceTime calls |
| Automation (per browser) | Reading the current tab URL in Arc, Safari or Chrome to spot meetings |
| Notifications | "Recording…", "Meeting ended?" and long-recording notices |

## Requirements

- Apple Silicon Mac. Intel is not supported.
- macOS 26 or later.
- RAM for local summaries: 32 GB recommended for Gemma 4 12B (multilingual,
  ~7 GB download) or Qwen3.5-9B; 16 GB works for Qwen3.5-4B.
- Disk: up to ~15 GB if you download every optional model.

## Files on disk

- `~/Documents/MeetingTranscripts/` — transcripts (`.md` + `.json`) and `tags.json`.
- `~/Documents/MeetingTranscripts/recordings/` — the paired `.voice.wav` and
  `.system.wav` files (and video, if recorded) for each session.
- `~/Documents/huggingface/models/` — downloaded summary models.
- Whisper models live in WhisperKit's own cache.

Deleting a transcript from the sidebar (right-click → Delete) removes its files.

## Build from source

Needs Xcode 26+ with the Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`), plus
`brew install xcodegen lame` (LAME is used only for MP3 export; the DMG
bundles its own).

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
or copy it into `/Applications`.

> **Why `-skipMacroValidation`?** MLX Swift LM ships compiler-plugin macros.
> Xcode asks you to trust them on first use; the flag skips that prompt. In the
> Xcode GUI, click "Trust & Enable" on the first build instead.

These commands use ad-hoc signing, so rebuilding or moving the app can make
macOS ask for permissions again. The DMG has a stable Developer ID signature.

### …or let an AI coding agent build it

Paste this into Claude Code, Codex or a similar agent:

> ```
> Build and install Simple Meeting Scribe from
> https://github.com/czlonkowski/simple-meeting-scribe on this Mac.
> Check it's Apple Silicon with macOS 26+ and Xcode 26+. Install missing
> tools with `brew install xcodegen lame` and
> `xcodebuild -downloadComponent MetalToolchain`. Clone the repo, run
> `xcodegen generate`, then build Release with the xcodebuild command from
> the README (add `-derivedDataPath build`). Copy the app to /Applications
> (ask me before using sudo). Then tell me to grant the permissions macOS
> asks for and to pick a transcription engine and summary model in
> Settings. If any step fails, stop and show me the exact error.
> ```

## Repo layout

```
MeetingTranscriber/
├── App/         # @main, AppState, menu-bar extra, notifications, updates
├── Capture/     # mic + system audio, process taps, meeting/call detection
├── Transcribe/  # Whisper, Parakeet, MAI, Scribe, diarization, pipeline
├── Summarize/   # MLX and Azure OpenAI summaries, prompts
├── Storage/     # transcripts, tags, glossary, summaries, Keychain
├── MCP/         # local MCP server and tools
├── Models/      # shared model types
├── UI/          # SwiftUI views
└── Resources/   # Info.plist, entitlements, meeting-patterns.json
```

`project.yml` drives everything — edit the YAML, run `xcodegen generate`,
never touch the `.xcodeproj` by hand.

## Contributions

I'm not taking pull requests. If you want to add something, fork it.
Issues are welcome as a place to discuss, but I make no promise to respond.

## License

MIT — see [LICENSE](LICENSE).
