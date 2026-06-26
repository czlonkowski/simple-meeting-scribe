# Gemma 4 Summarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the three Bielik models and add Gemma 4 as the unified default summarization model for both English and Polish.

> **Revision (during implementation):** Final review caught that the planned
> `mlx-community/gemma-4-12B-it-8bit` is `gemma4_unified` arch, unsupported by
> the pinned `mlx-swift-lm` 3.31.3 (and absent from `main`). Switched to
> `mlx-community/gemma-4-26b-a4b-it-4bit` (`gemma4` arch, supported; MoE ~4B
> active, ~14 GB). Implemented as commit `8a1461f` on top of Task 2. The Task 2
> code blocks below still describe the original 12B values — the shipped enum
> uses the 26B-A4B repo ID and `gemma4-26b-a4b-4bit` short name instead.

**Architecture:** `SummarizationEngine` loads one MLX `ModelContainer` and drives it with `ChatSession`. Gemma 4 is a VLM-class arch (`gemma4_unified`), so it loads through `VLMModelFactory` instead of the text-only `LLMModelFactory`; text-only generation works unchanged on the resulting container. A per-model `loadsViaVLMFactory` flag selects the factory.

**Tech Stack:** Swift / SwiftUI (macOS), MLX Swift via `mlx-swift-lm` 3.31.3 (`MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, **new: `MLXVLM`**), swift-huggingface.

## Global Constraints

- Single Xcode target: `MeetingTranscriber` (scheme `MeetingTranscriber`, project `MeetingTranscriber.xcodeproj`). No XCTest target exists — **verification is `xcodebuild` build-green at every task boundary + a manual functional run at the end.**
- New model repo ID (exact, case-sensitive): `mlx-community/gemma-4-12B-it-8bit`.
- Gemma 4 is the default for **both** `.english` and `.polish`. Qwen3.5 models stay selectable. Bielik removed entirely.
- `loadContainer` signature (shared by both factories, from `GenericModelFactory`): `loadContainer(from: any Downloader, using: any TokenizerLoader, configuration: ModelConfiguration, useLatest: Bool = false, progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> ModelContainer`.
- Build command used throughout: `xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -configuration Debug build 2>&1 | tail -25` (expect `** BUILD SUCCEEDED **`).
- Commit messages end with the trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: Link the MLXVLM Swift package product to the app target

**Files:**
- Modify: `MeetingTranscriber.xcodeproj/project.pbxproj` (4 insertions)

**Interfaces:**
- Consumes: the already-referenced `mlx-swift-lm` package (`XCRemoteSwiftPackageReference` id `2066287E7399F3E26F676AB4`).
- Produces: `import MLXVLM` becomes available to the target (used in Task 3). Two new pbxproj object IDs: build-file `9F1A2B3C4D5E6F7081920304`, product-dependency `0A1B2C3D4E5F60718293A4B5`.

- [ ] **Step 1: Confirm the two new object IDs are unused**

Run: `grep -c "9F1A2B3C4D5E6F7081920304\|0A1B2C3D4E5F60718293A4B5" MeetingTranscriber.xcodeproj/project.pbxproj`
Expected: `0`. (If non-zero, pick other random 24-hex-char IDs and substitute them consistently in all 4 edits below.)

- [ ] **Step 2: Add the `PBXBuildFile` entry**

Find this line (PBXBuildFile section):
```
		2B949EB0180E613EB8577CF0 /* MLXLLM in Frameworks */ = {isa = PBXBuildFile; productRef = A22BC7E86E01210214EADBA8 /* MLXLLM */; };
```
Insert immediately after it:
```
		9F1A2B3C4D5E6F7081920304 /* MLXVLM in Frameworks */ = {isa = PBXBuildFile; productRef = 0A1B2C3D4E5F60718293A4B5 /* MLXVLM */; };
```

- [ ] **Step 3: Add MLXVLM to the Frameworks build phase**

Find this line (inside `PBXFrameworksBuildPhase` → `files = (`):
```
				2B949EB0180E613EB8577CF0 /* MLXLLM in Frameworks */,
```
Insert immediately after it:
```
				9F1A2B3C4D5E6F7081920304 /* MLXVLM in Frameworks */,
```

- [ ] **Step 4: Add MLXVLM to the target's `packageProductDependencies`**

Find this line (inside `packageProductDependencies = (`):
```
				A22BC7E86E01210214EADBA8 /* MLXLLM */,
```
Insert immediately after it:
```
				0A1B2C3D4E5F60718293A4B5 /* MLXVLM */,
```

- [ ] **Step 5: Add the `XCSwiftPackageProductDependency` definition**

Find this block (in the `XCSwiftPackageProductDependency` section):
```
		A22BC7E86E01210214EADBA8 /* MLXLLM */ = {
			isa = XCSwiftPackageProductDependency;
			package = 2066287E7399F3E26F676AB4 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;
			productName = MLXLLM;
		};
```
Insert immediately after that closing `};`:
```
		0A1B2C3D4E5F60718293A4B5 /* MLXVLM */ = {
			isa = XCSwiftPackageProductDependency;
			package = 2066287E7399F3E26F676AB4 /* XCRemoteSwiftPackageReference "mlx-swift-lm" */;
			productName = MLXVLM;
		};
```

- [ ] **Step 6: Resolve packages and build to verify the project is still valid**

Run: `xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -resolvePackageDependencies 2>&1 | tail -5 && xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -configuration Debug build 2>&1 | tail -25`
Expected: package graph resolves (MLXVLM among `mlx-swift-lm` products) and `** BUILD SUCCEEDED **`. (MLXVLM is linked but unused yet — that is fine.)

- [ ] **Step 7: Commit**

```bash
git add MeetingTranscriber.xcodeproj/project.pbxproj
git commit -m "build: link MLXVLM product for Gemma 4 support

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Swap Bielik → Gemma 4 in the model enum and default

**Files:**
- Modify: `MeetingTranscriber/Summarize/LanguageModel.swift` (full rewrite)
- Modify: `MeetingTranscriber/Storage/SummaryStore.swift:20-25` (`defaultModel(for:)`)

**Interfaces:**
- Produces: `LanguageModel.gemma4_12b_it_mlx_8bit` (rawValue `"mlx-community/gemma-4-12B-it-8bit"`); new property `LanguageModel.loadsViaVLMFactory: Bool` (consumed by Task 3). Removes `bielik_11b_v3_mlx_8bit`, `bielik_11b_v3_mlx_4bit`, `bielik_4_5b_v3_mlx_8bit`.
- Consumes: `TranscriptionLanguage` (`.polish`, `.english`).

Note: the two changes are compile-coupled — `SummaryStore.defaultModel(.polish)` currently returns a Bielik case, so removing the case forces the store edit in the same task to keep the build green.

- [ ] **Step 1: Replace the entire contents of `LanguageModel.swift`**

```swift
import Foundation

/// Local LLMs used for transcript summarization. Identified by their
/// HuggingFace repo ID. Text-only models load through MLXLLM's
/// `LLMModelFactory`; VLM-class models (Gemma 4 is `gemma4_unified`) load
/// through `VLMModelFactory` — see `loadsViaVLMFactory`.
enum LanguageModel: String, CaseIterable, Codable, Identifiable, Hashable {
    case gemma4_12b_it_mlx_8bit = "mlx-community/gemma-4-12B-it-8bit"
    case qwen3_5_4b_mlx_8bit    = "mlx-community/Qwen3.5-4B-8bit"
    case qwen3_5_9b_mlx_4bit    = "mlx-community/Qwen3.5-9B-MLX-4bit"

    var id: String { rawValue }
    var repoID: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4_12b_it_mlx_8bit: "Gemma 4 12B 8-bit (Multilingual, ~13 GB — recommended)"
        case .qwen3_5_4b_mlx_8bit:    "Qwen3.5-4B 8-bit (English, ~1.5 GB)"
        case .qwen3_5_9b_mlx_4bit:    "Qwen3.5-9B (English, ~5 GB — better quality)"
        }
    }

    var approxDownloadGB: Double {
        switch self {
        case .gemma4_12b_it_mlx_8bit: 13.0
        case .qwen3_5_4b_mlx_8bit:    1.5
        case .qwen3_5_9b_mlx_4bit:    5.0
        }
    }

    var approxActiveMemoryGB: Double {
        switch self {
        case .gemma4_12b_it_mlx_8bit: 14.0
        case .qwen3_5_4b_mlx_8bit:    4.0
        case .qwen3_5_9b_mlx_4bit:    7.0
        }
    }

    var supportedLanguages: Set<TranscriptionLanguage> {
        switch self {
        // Gemma 4 is multilingual (140+ languages pretrained, Polish included).
        case .gemma4_12b_it_mlx_8bit: [.polish, .english]
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    [.english]
        }
    }

    var shortName: String {
        switch self {
        case .gemma4_12b_it_mlx_8bit: "gemma4-12b-8bit"
        case .qwen3_5_4b_mlx_8bit:    "qwen3.5-4b-8bit"
        case .qwen3_5_9b_mlx_4bit:    "qwen3.5-9b"
        }
    }

    /// Qwen3 / Qwen3.5 ship a hybrid reasoning mode that emits `<think>…</think>`
    /// blocks before the answer. For summarization we only want the final
    /// answer, so we pass `enable_thinking=false` through the chat template
    /// context and strip leaked thought tags at display time. Gemma 4 has no
    /// such mode.
    var usesThinkingMode: Bool {
        switch self {
        case .gemma4_12b_it_mlx_8bit: false
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    true
        }
    }

    /// Gemma 4 (`gemma4_unified`) is a VLM-class architecture and is NOT in the
    /// text-only `LLMModelFactory` registry — it must load through
    /// `VLMModelFactory`. Text-only generation works fine on the resulting
    /// container (no image input). Qwen text models load via `LLMModelFactory`.
    var loadsViaVLMFactory: Bool {
        switch self {
        case .gemma4_12b_it_mlx_8bit: true
        case .qwen3_5_4b_mlx_8bit,
             .qwen3_5_9b_mlx_4bit:    false
        }
    }
}
```

- [ ] **Step 2: Point the per-language default at Gemma 4 in `SummaryStore.swift`**

Replace:
```swift
    static func defaultModel(for language: TranscriptionLanguage) -> LanguageModel {
        switch language {
        case .english: return .qwen3_5_4b_mlx_8bit
        case .polish:  return .bielik_11b_v3_mlx_8bit
        }
    }
```
With:
```swift
    static func defaultModel(for language: TranscriptionLanguage) -> LanguageModel {
        // Gemma 4 is the unified multilingual default for both languages.
        switch language {
        case .english: return .gemma4_12b_it_mlx_8bit
        case .polish:  return .gemma4_12b_it_mlx_8bit
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -configuration Debug build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`. (Gemma still loads via `LLMModelFactory` at this point — fixed in Task 3 — but it compiles.)

- [ ] **Step 4: Commit**

```bash
git add MeetingTranscriber/Summarize/LanguageModel.swift MeetingTranscriber/Storage/SummaryStore.swift
git commit -m "feat: replace Bielik with Gemma 4 12B as unified default model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Route Gemma 4 through VLMModelFactory and raise the memory cap

**Files:**
- Modify: `MeetingTranscriber/Summarize/SummarizationEngine.swift`

**Interfaces:**
- Consumes: `LanguageModel.loadsViaVLMFactory` (Task 2), `MLXVLM.VLMModelFactory` (Task 1), `MLXLMCommon.ModelContainer` / `Progress` / `#hubDownloader()` / `#huggingFaceTokenizerLoader()`.
- Produces: a private `loadContainer(for:progress:)` helper that both `ensureLoaded` and `prefetch` call.

- [ ] **Step 1: Add the MLXVLM import**

Replace:
```swift
import MLXLLM
import MLXLMCommon
```
With:
```swift
import MLXLLM
import MLXLMCommon
import MLXVLM
```

- [ ] **Step 2: Raise the MLX memory cap to 16 GB**

Replace:
```swift
        // 12 GB hard cap on MLX allocations. On a 32 GB M-series Mac this
        // leaves ~20 GB for the OS, Whisper (CoreML/ANE), browser, etc.
        let memLimitBytes = 12 * 1024 * 1024 * 1024
```
With:
```swift
        // 16 GB cap on MLX allocations — Gemma 4 12B 8-bit needs ~14 GB active.
        // On a 32 GB M-series Mac this still leaves ~16 GB for the OS, Whisper
        // (CoreML/ANE), browser, etc. memoryLimit is a soft recycle threshold,
        // not a hard ceiling, so brief spikes on long transcripts are tolerated.
        let memLimitBytes = 16 * 1024 * 1024 * 1024
```

- [ ] **Step 3: Add a private factory-selecting loader helper**

Insert this method inside the `SummarizationEngine` actor, immediately above the `// MARK: - Load / download` comment:
```swift
    /// Load `model`'s container through the correct MLX factory. Gemma 4 is a
    /// VLM-class arch and must go through `VLMModelFactory`; Qwen text models
    /// go through `LLMModelFactory`. Both return an `MLXLMCommon.ModelContainer`
    /// that `ChatSession` drives identically for text-only generation.
    private func loadContainer(
        for model: LanguageModel,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        let config = ModelConfiguration(id: model.repoID)
        if model.loadsViaVLMFactory {
            return try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: config,
                progressHandler: progress
            )
        } else {
            return try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: config,
                progressHandler: progress
            )
        }
    }
```

- [ ] **Step 4: Use the helper in `ensureLoaded`**

Replace:
```swift
        let config = ModelConfiguration(id: model.repoID)
        let c = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: config
        ) { p in
            progress(p.fractionCompleted)
        }
        self.container = c
        self.activeModelID = model.repoID
```
With:
```swift
        let c = try await loadContainer(for: model) { p in
            progress(p.fractionCompleted)
        }
        self.container = c
        self.activeModelID = model.repoID
```

- [ ] **Step 5: Use the helper in `prefetch`**

Replace:
```swift
        let config = ModelConfiguration(id: model.repoID)
        _ = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: config
        ) { p in
            Log.summary.debug(
                "loadContainer progress fractionCompleted=\(p.fractionCompleted, privacy: .public) completed=\(p.completedUnitCount, privacy: .public) total=\(p.totalUnitCount, privacy: .public)"
            )
            progress(p.fractionCompleted)
        }
```
With:
```swift
        _ = try await loadContainer(for: model) { p in
            Log.summary.debug(
                "loadContainer progress fractionCompleted=\(p.fractionCompleted, privacy: .public) completed=\(p.completedUnitCount, privacy: .public) total=\(p.totalUnitCount, privacy: .public)"
            )
            progress(p.fractionCompleted)
        }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -configuration Debug build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add MeetingTranscriber/Summarize/SummarizationEngine.swift
git commit -m "feat: load Gemma 4 via VLMModelFactory, raise MLX cap to 16 GB

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Decode removed model overrides leniently (migration safety)

**Files:**
- Modify: `MeetingTranscriber/Models/Models.swift` (add an extension to `TranscriptDocument`)

**Interfaces:**
- Consumes: the synthesized `TranscriptDocument.CodingKeys` and the `Codable` sub-types (`TranscriptionLanguage`, `SourceKind`, `SpeakerLabel`, `TranscriptSegment`, `LanguageModel`).
- Produces: a custom `init(from:)` so a stored `summaryModelOverride` whose rawValue no longer maps to a case (e.g. an old Bielik repo ID) decodes to `nil` instead of throwing — preventing `TranscriptStore.loadAll()` from skipping the whole transcript.

Why an extension (not the struct body): putting `init(from:)` in an extension preserves the compiler-synthesized **memberwise** initializer that `TranscriptionPipeline` and others use to build documents. The synthesized `encode(to:)` and `CodingKeys` are still generated.

- [ ] **Step 1: Add the lenient-decoding extension**

Insert this extension in `Models.swift` immediately after the closing brace of `struct TranscriptDocument { … }` (after line 141):
```swift
extension TranscriptDocument {
    /// Custom decoder that tolerates a `summaryModelOverride` referring to a
    /// model that no longer exists (e.g. a removed Bielik repo ID): it decodes
    /// to `nil` rather than throwing, so old transcripts still load. All other
    /// fields decode exactly as the synthesized initializer would.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        language = try c.decode(TranscriptionLanguage.self, forKey: .language)
        modelShortName = try c.decode(String.self, forKey: .modelShortName)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        sourceKind = try c.decode(SourceKind.self, forKey: .sourceKind)
        speakers = try c.decode([SpeakerLabel].self, forKey: .speakers)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        videoFileName = try c.decodeIfPresent(String.self, forKey: .videoFileName)
        videoStartOffset = try c.decodeIfPresent(Double.self, forKey: .videoStartOffset)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryModelShortName = try c.decodeIfPresent(String.self, forKey: .summaryModelShortName)
        summaryGeneratedAt = try c.decodeIfPresent(Date.self, forKey: .summaryGeneratedAt)
        // Lenient: present-but-unknown rawValue throws inside decodeIfPresent,
        // which `try?` turns into nil; absent key also yields nil.
        summaryModelOverride = (try? c.decodeIfPresent(LanguageModel.self, forKey: .summaryModelOverride)) ?? nil
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -configuration Debug build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`. (A compile error here usually means the field list drifted from the struct — re-check property names/types against `struct TranscriptDocument`.)

- [ ] **Step 3: Manual migration check (only if a Bielik-override transcript exists)**

The transcript store lives under `~/Documents` (see `TranscriptStore`). If any saved `*.json` transcript contains `"summaryModelOverride":"speakleash/Bielik-...`, note its `id`. After the functional run in Task 6, confirm that transcript still appears in the list. If you have none, this is covered by the build + the logic above; state that explicitly rather than claiming it was exercised.

Run (to find any affected transcripts): `grep -rl '"summaryModelOverride":"speakleash/Bielik' ~/Documents 2>/dev/null`
Expected: a list of files (possibly empty). Empty ⇒ nothing to migrate.

- [ ] **Step 4: Commit**

```bash
git add MeetingTranscriber/Models/Models.swift
git commit -m "fix: decode removed model overrides as nil so old transcripts load

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Drop model names from the system-prompt editor labels

**Files:**
- Modify: `MeetingTranscriber/UI/SettingsView.swift:284` and `:305`

**Interfaces:** none (UI string-only change). The "Model library" section iterates `LanguageModel.allCases` and updates automatically.

- [ ] **Step 1: Relabel the English editor**

Replace:
```swift
                    Text("English (Qwen3.5)").font(.subheadline).foregroundStyle(.secondary)
```
With:
```swift
                    Text("English").font(.subheadline).foregroundStyle(.secondary)
```

- [ ] **Step 2: Relabel the Polish editor**

Replace:
```swift
                    Text("Polish (Bielik)").font(.subheadline).foregroundStyle(.secondary)
```
With:
```swift
                    Text("Polish").font(.subheadline).foregroundStyle(.secondary)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project MeetingTranscriber.xcodeproj -scheme MeetingTranscriber -configuration Debug build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add MeetingTranscriber/UI/SettingsView.swift
git commit -m "ui: drop model names from system-prompt editor labels

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Functional verification (install + summarize EN & PL)

**Files:** none (runtime verification).

**Interfaces:** Consumes everything above. This is the proof for the one runtime unknown — that `VLMModelFactory` + `ChatSession` produce correct text-only output for Gemma 4.

- [ ] **Step 1: Build & install the Debug app**

Run: `scripts/reinstall.sh`
Expected: builds, swaps `/Applications/MeetingTranscriber.app`, relaunches (one admin prompt). No build errors.

- [ ] **Step 2: Verify the model list**

In the running app: Settings → "Model library". Expected rows: **Gemma 4 12B 8-bit**, **Qwen3.5-4B 8-bit**, **Qwen3.5-9B** — and **no Bielik**. The system-prompt section shows plain "English" / "Polish" headers.

- [ ] **Step 3: Summarize an English transcript**

Open an existing English transcript and click Summarize (or Regenerate). Expected: status shows "loading model" (first run downloads ~13 GB from `mlx-community/gemma-4-12B-it-8bit` — this is slow once), then a summary streams in, followed by a generated title. Confirm the summary text is coherent English, not empty/garbled.

- [ ] **Step 4: Summarize a Polish transcript**

Open a Polish transcript and Summarize. Expected: a coherent Polish summary streams in (Gemma 4 replacing Bielik). Sanity-check that names/terms are preserved and the output is in Polish. If quality is unacceptable, that's a model-choice decision to raise with the user — not a code bug.

- [ ] **Step 5: Confirm migration (if applicable)**

If Task 4 Step 3 found Bielik-override transcripts, confirm each still appears in the transcript list and opens normally. If none existed, state that no migration case was present to exercise.

- [ ] **Step 6: Final confirmation**

Report: build succeeded, model list correct, EN + PL summaries generated via the VLM path, migration status. No commit (verification only).

---

## Self-Review

**Spec coverage:**
- Remove Bielik → Task 2 (enum) + Task 5 (label). ✓
- Add Gemma 4 12B 8-bit → Task 2. ✓
- Unified EN+PL default → Task 2 Step 2. ✓
- VLMModelFactory routing → Task 1 (link) + Task 3 (route). ✓
- Memory cap bump → Task 3 Step 2. ✓
- Lenient `summaryModelOverride` migration → Task 4. ✓
- SettingsView relabel → Task 5. ✓
- Verification (build + EN/PL run + migration) → Task 6. ✓
- Out of scope (audio, 4-bit variant, transcription) → not in any task. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; every run step has an expected result. ✓

**Type consistency:** `loadsViaVLMFactory` (Task 2) ↔ used in Task 3 helper. `loadContainer(for:progress:)` defined and called consistently in Task 3. `gemma4_12b_it_mlx_8bit` rawValue identical in enum (Task 2) and verification (Task 6). `CodingKeys` / field names in Task 4 match `struct TranscriptDocument`. ✓
