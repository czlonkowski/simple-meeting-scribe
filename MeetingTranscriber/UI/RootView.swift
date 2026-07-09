import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case record
    case transcript(String)
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    /// Sheet-item wrapper for a file awaiting import options (engine + language).
    private struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
    }

    @State private var selection: SidebarItem? = .record
    @State private var query: String = ""
    @State private var showFileImporter: Bool = false
    @State private var pendingImport: PendingImport? = nil
    @State private var pendingDelete: TranscriptDocument? = nil
    @State private var activeTagFilters: Set<String> = []
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
        if query.isEmpty && activeTagFilters.isEmpty && !showShortRecordings {
            base = appState.transcripts.filter { !Self.isGhostRecording($0) }
        } else {
            base = appState.transcripts
        }

        let tagFiltered = activeTagFilters.isEmpty
            ? base
            : base.filter { doc in
                let docTags = Set(doc.tags.map { TagStore.key(for: $0) })
                return activeTagFilters.allSatisfy { docTags.contains($0) }
            }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tagFiltered }
        return tagFiltered.filter { doc in
            doc.title.lowercased().contains(q) ||
            doc.segments.contains(where: { $0.text.lowercased().contains(q) }) ||
            doc.tags.contains(where: { $0.lowercased().contains(q) })
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
                pendingImport = PendingImport(url: first)
            }
        }
        .sheet(item: $pendingImport) { pending in
            ImportFileSheet(url: pending.url)
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
            pendingImport = PendingImport(url: first)
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
                            // Two-finger swipe left reveals Delete; a full
                            // swipe deletes outright (no confirmation —
                            // matching the swipe-to-delete idiom).
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    appState.deleteTranscript(id: doc.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
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
                            HStack(spacing: Theme.space3) {
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
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
        .navigationTitle("Meeting Transcriber")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        .searchable(text: $query, placement: .sidebar, prompt: "Search transcripts and tags")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                tagFilterMenu
            }
        }
    }

    @ViewBuilder private var tagFilterMenu: some View {
        Menu {
            if !activeTagFilters.isEmpty {
                Button("Clear tag filters") {
                    activeTagFilters.removeAll()
                }
                Divider()
            }

            if appState.tagCatalog.isEmpty {
                Text("No tags")
            } else {
                ForEach(appState.tagCatalog) { tag in
                    let key = TagStore.key(for: tag.name)
                    Button {
                        toggleTagFilter(tag.name)
                    } label: {
                        HStack(spacing: Theme.space4) {
                            Image(systemName: "checkmark")
                                .opacity(activeTagFilters.contains(key) ? 1 : 0)
                            Circle()
                                .fill(tag.color.swiftUIColor)
                                .frame(width: 8, height: 8)
                                .chipHover()
                            Text(tag.name)
                        }
                    }
                }
            }
        } label: {
            Label("Tags", systemImage: activeTagFilters.isEmpty ? "tag" : "tag.fill")
        }
        .help("Filter transcripts by tag")
    }

    private func toggleTagFilter(_ tagName: String) {
        let key = TagStore.key(for: tagName)
        if activeTagFilters.contains(key) {
            activeTagFilters.remove(key)
        } else {
            activeTagFilters.insert(key)
        }
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

}
