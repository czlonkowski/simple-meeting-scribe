# Replace Bielik with Gemma 4 as the summarization model

**Date:** 2026-06-26
**Status:** Implemented — pending interactive functional run (Task 6)

> **Revision (2026-06-26, during implementation):** The chosen model changed
> from **Gemma 4 12B 8-bit** to **Gemma 4 26B-A4B 4-bit**
> (`mlx-community/gemma-4-26b-a4b-it-4bit`). Reason: the 12B variant uses the
> newer `gemma4_unified` architecture, which **no released or `main` version of
> `mlx-swift-lm` registers** (the library knows `gemma4` only; the 12B was
> released after the library's last commit). Confirmed by inspecting the
> resolved package sources and independently by Codex. The 26B-A4B is a
> library-blessed `gemma4`-arch MoE preset (~4B active params, ~14 GB at 4-bit,
> multilingual) — similar footprint, runs on the pinned library via the same
> VLM path. Everything else below stands; substitute the 26B-A4B repo ID for
> the 12B one throughout.

## Summary

Remove the three Bielik models from the local summarization model list and add
Google **Gemma 4 12B Instruct** (`mlx-community/gemma-4-12B-it-8bit`) as the new
**unified default for both English and Polish**. Qwen3.5 models stay selectable.
This is a **text-only** summarization change — the originally-discussed
"feed transcript + audio together" idea is dropped as infeasible (see below).

## Background

The app summarizes transcripts locally via MLX Swift (`mlx-swift-lm`). One
`SummarizationEngine` actor loads at most one `ModelContainer` through
`LLMModelFactory.shared.loadContainer(...)` and drives it with `ChatSession`
(text in → streamed text out). Models are an enum `LanguageModel` keyed by
HuggingFace repo ID. Current list: two Qwen3.5 (English) + three Bielik (Polish).
The user does not use Bielik and wants Gemma 4 instead.

## Feasibility finding: audio + transcript together is NOT buildable

The user's original idea was to feed Gemma 4 the transcript **and** the meeting
audio simultaneously. Verified against the live model card and the MLX Swift
source — this is blocked by two independent walls:

1. **Gemma 4 caps audio input at 30 seconds.** Model card: *"Audio supports a
   maximum length of 30 seconds."* Meetings are 20–90 minutes, so the meeting
   audio cannot be fed to the model at all. The audio modality targets short
   clips / voice notes / short-utterance ASR.
2. **MLX Swift has no audio-input path.** `mlx-swift-lm`'s `VLMModelFactory`
   registers `gemma4` / `gemma4_unified` but only wires up **images and video**
   (error types `imageRequired`, `videoRequired`, … — nothing for audio). Even
   30 s clips are not feedable without building an audio encoder into the
   library, which does not exist today.

**Decision:** drop audio. Revisit only if MLX Swift gains an audio encoder *and*
a long-audio-capable local model appears.

## Decisions (confirmed with user)

- **Drop audio**, ship a text-only Gemma 4 summarizer.
- **Gemma 4 12B 8-bit** (`mlx-community/gemma-4-12B-it-8bit`, ~13 GB) becomes the
  **default for both EN and PL** (one multilingual model). Qwen3.5 stays
  available for English. Bielik removed entirely.
- Target machine is M5 / 32 GB; 8-bit is comfortable.

## Why Gemma 4 is a good swap

- Multilingual (140+ languages pretrained; Polish well-covered) — replaces the
  Polish-specialized Bielik with a newer, stronger base.
- 256K context → long meetings never truncate.
- Already available as MLX quants and registered in the MLX Swift VLM factory.

## Change spec (6 files)

### 1. `MeetingTranscriber/Summarize/LanguageModel.swift`
- Remove the three `bielik_*` cases.
- Add `case gemma4_12b_it_mlx_8bit = "mlx-community/gemma-4-12B-it-8bit"`,
  ordered first (it is the new recommended default).
- Switch arms for the new case:
  - `displayName`: e.g. `"Gemma 4 12B 8-bit (Multilingual, ~13 GB — recommended)"`
  - `approxDownloadGB`: `13.0`
  - `approxActiveMemoryGB`: `14.0`
  - `supportedLanguages`: `[.polish, .english]`
  - `shortName`: `"gemma4-12b-8bit"`
  - `usesThinkingMode`: `false`
- Add a new computed property `loadsViaVLMFactory: Bool` — `true` for Gemma 4,
  `false` for the Qwen models. Gemma 4 is a VLM-class arch (`gemma4_unified`)
  and is **not** in the text-only `LLMModelFactory` registry; it must load via
  `VLMModelFactory`.

### 2. `MeetingTranscriber/Summarize/SummarizationEngine.swift`
- `import MLXVLM`.
- In `ensureLoaded(_:progress:)` and `prefetch(_:progress:)`, branch on
  `model.loadsViaVLMFactory`:
  - `true`  → `VLMModelFactory.shared.loadContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: config) { … }`
  - `false` → existing `LLMModelFactory.shared.loadContainer(...)`
  Both return `MLXLMCommon.ModelContainer`; assign to the same `container`.
  `stream()` / `ChatSession` are unchanged (text-only generation works on a VLM
  container with no image input).
- Bump the MLX memory cap in `configureMemoryBudgetOnce()` from **12 GB → 16 GB**
  (12B-8bit ≈ 14 GB active; 32 GB machine has headroom). Update the comment.
  Note: `memoryLimit` is a soft recycle threshold, not a hard ceiling.

### 3. `MeetingTranscriber/Storage/SummaryStore.swift`
- `defaultModel(for:)` returns `.gemma4_12b_it_mlx_8bit` for **both** `.english`
  and `.polish`.
- No explicit migration code needed for persisted per-language defaults:
  `loadDefaultModel` already falls back to `defaultModel(for:)` when a stored raw
  value (an old Bielik repo ID) no longer maps to a case.

### 4. `MeetingTranscriber/Models/Models.swift`
- **Migration safety.** `TranscriptDocument` persists `summaryModelOverride:
  LanguageModel?` per file. `TranscriptStore.loadAll()` **silently skips** any
  document whose JSON fails to decode. With the Bielik cases removed, a stored
  override pointing at a Bielik repo ID would throw on decode and make that whole
  transcript disappear from the list.
- Fix: add a custom `init(from decoder:)` to `TranscriptDocument` that decodes
  every field normally **except** `summaryModelOverride`, which is decoded
  leniently (`try?` → unknown/removed model becomes `nil`). Keep the synthesized
  `encode(to:)`. The custom init references the (synthesized) `CodingKeys`.

### 5. `MeetingTranscriber/UI/SettingsView.swift`
- Relabel the two system-prompt editors:
  - `"English (Qwen3.5)"` → `"English"`
  - `"Polish (Bielik)"`   → `"Polish"`
  (Model choice is now user-selectable per language, so labels should not name a
  model.)
- The "Model library" section iterates `LanguageModel.allCases` and updates
  automatically — no change there.

### 6. `MeetingTranscriber.xcodeproj/project.pbxproj`
- Add the **`MLXVLM`** product (from the already-referenced `mlx-swift-lm`
  package) to the app target, mirroring the existing `MLXLLM` wiring:
  - a `PBXBuildFile` ("MLXVLM in Frameworks"),
  - an `XCSwiftPackageProductDependency` referencing the `mlx-swift-lm` package,
  - entries in the target's `packageProductDependencies` and the Frameworks
    build phase.
- Careful, surgical edit — a malformed pbxproj breaks the project. Verify by
  building.

## Risks & verification

- **Runtime unknown (primary):** that `VLMModelFactory` + `ChatSession` produce
  correct **text-only** output for Gemma 4. High confidence (standard mlx-swift
  usage), but proven only by a real run. Verify: build Debug, then run one live
  summary (first run pulls ~13 GB) and confirm streamed text on an English and a
  Polish transcript.
- **Polish quality regression:** swapping a Polish-specialized model (Bielik) for
  a multilingual one. Mitigation: sanity-check a Polish transcript summary; the
  per-language system prompts (kept) already steer "answer in the transcript
  language."
- **Memory:** if a very long meeting OOMs at the 16 GB cap, raise toward ~18 GB
  (still safe on 32 GB).
- **pbxproj edit:** validated by a successful `xcodebuild` of the target.

## Out of scope / YAGNI

- Audio input of any kind.
- A 4-bit Gemma variant (trivial one-case add later if a lighter Polish option is
  wanted; user chose 8-bit).
- Any change to transcription (Whisper/Scribe), diarization, or MCP.

## Verification plan

1. `xcodebuild` Debug build succeeds (enum removal forces fixing every switch;
   VLM call + pbxproj must compile/resolve).
2. Launch app; Settings → Model library lists Gemma 4 + the two Qwen models, no
   Bielik.
3. Run a summary on an English transcript and a Polish transcript — confirm the
   model downloads, loads via the VLM path, and streams a coherent summary +
   title.
4. Confirm an existing transcript that had a Bielik per-meeting override (if any)
   still loads and shows in the list.
