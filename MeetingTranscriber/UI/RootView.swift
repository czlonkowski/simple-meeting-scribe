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

    private var filteredTranscripts: [TranscriptDocument] {
        guard !query.isEmpty else { return appState.transcripts }
        let q = query.lowercased()
        return appState.transcripts.filter { doc in
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
                .disabled(state.recordingState.isBusy)
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
            guard case .idle = appState.recordingState,
                  let first = urls.first else { return false }
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
