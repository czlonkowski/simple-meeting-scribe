import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case record
    case transcript(String)
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    @State private var selection: SidebarItem? = .record
    @State private var query: String = ""
    @State private var showFileImporter: Bool = false
    @State private var pendingImportURL: URL? = nil
    @State private var pendingDelete: TranscriptDocument? = nil
    /// When false (the default), recordings under `ghostDurationThreshold`
    /// with no usable segments are hidden from the sidebar — see
    /// `isGhostRecording`. Search overrides this so a query always finds
    /// every match.
    @State private var showShortRecordings: Bool = false

    /// Recordings shorter than this AND with no extracted speech are
    /// considered "ghosts" — typically aborted recordings that captured
    /// silence or a stray click. 15 seconds is conservative enough that
    /// a real one-sentence note would still survive.
    private static let ghostDurationThreshold: TimeInterval = 15

    private static func isGhostRecording(_ doc: TranscriptDocument) -> Bool {
        guard doc.duration < ghostDurationThreshold else { return false }
        let combinedText = doc.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined()
        return combinedText.count < 12
    }

    private var ghostCount: Int {
        appState.transcripts.filter(Self.isGhostRecording).count
    }

    private var filteredTranscripts: [TranscriptDocument] {
        let base: [TranscriptDocument]
        if query.isEmpty && !showShortRecordings {
            base = appState.transcripts.filter { !Self.isGhostRecording($0) }
        } else {
            base = appState.transcripts
        }
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter { doc in
            doc.title.lowercased().contains(q) ||
            doc.segments.contains(where: { $0.text.lowercased().contains(q) })
        }
    }

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import File", systemImage: "tray.and.arrow.down")
                }
                .help("Import an audio or video file for transcription")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings (⌘,)")
            }
        }
        .sheet(item: $state.detectedMeeting) { meeting in
            MeetingJoinSheet(meeting: meeting)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                pendingImportURL = first
            }
        }
        .confirmationDialog(
            "Language of \(pendingImportURL?.lastPathComponent ?? "file")",
            isPresented: Binding(
                get: { pendingImportURL != nil },
                set: { if !$0 { pendingImportURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("🇬🇧 English") { startImport(language: .english) }
            Button("🇵🇱 Polski") { startImport(language: .polish) }
            Button("Cancel", role: .cancel) { pendingImportURL = nil }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(appState.lastError ?? "")
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)”?" } ?? "Delete transcript?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { doc in
            Button("Delete", role: .destructive) {
                appState.deleteTranscript(id: doc.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Removes the transcript, its JSON, and paired audio recordings. This cannot be undone.")
        }
        .onChange(of: appState.importPanelRequested) {
            showFileImporter = true
        }
        .onChange(of: appState.selectedTranscriptID) { _, newID in
            if let id = newID { selection = .transcript(id) }
        }
        .onChange(of: selection) { _, newValue in
            if case .transcript(let id) = newValue {
                appState.selectedTranscriptID = id
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            pendingImportURL = first
            return true
        }
    }

    // MARK: – Sidebar
    @ViewBuilder private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Record", systemImage: "record.circle")
                    .tag(SidebarItem.record)
            }

            if !appState.transcripts.isEmpty {
                Section("Transcripts") {
                    ForEach(filteredTranscripts) { doc in
                        TranscriptListRow(doc: doc)
                            .tag(SidebarItem.transcript(doc.id))
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [TranscriptStore.shared.rootURL.appendingPathComponent("\(doc.id).md")]
                                    )
                                }
                                Divider()
                                Button("Delete…", role: .destructive) {
                                    pendingDelete = doc
                                }
                            }
                    }

                    let hiddenCount = ghostCount
                    if query.isEmpty && hiddenCount > 0 {
                        Button {
                            showShortRecordings.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showShortRecordings
                                      ? "eye.slash"
                                      : "eye")
                                Text(showShortRecordings
                                     ? "Hide \(hiddenCount) short recording\(hiddenCount == 1 ? "" : "s")"
                                     : "Show \(hiddenCount) short recording\(hiddenCount == 1 ? "" : "s")")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Meeting Transcriber")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        .searchable(text: $query, placement: .sidebar, prompt: "Search transcripts")
    }

    // MARK: – Detail
    @ViewBuilder private var detail: some View {
        switch selection {
        case .record, .none:
            RecordView()
        case .transcript(let id):
            TranscriptDetailView(documentID: id)
                .id(id)
        }
    }

    // MARK: – Import helpers
    private func startImport(language: TranscriptionLanguage) {
        guard let url = pendingImportURL else { return }
        pendingImportURL = nil
        Task { await appState.importFile(url: url, language: language) }
    }
}
