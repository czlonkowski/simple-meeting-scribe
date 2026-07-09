import Foundation
import MCP

/// Tool catalog and dispatcher for the local MCP server. Read tools load from
/// disk through `TranscriptStore`/`TagStore`; the tag write tool routes through
/// `AppState` so the open app updates live.
enum MCPTools {

    // MARK: - Definitions

    static let definitions: [Tool] = [
        Tool(
            name: "list_transcripts",
            description: """
                List transcripts stored by Meeting Transcriber. Returns a JSON \
                array sorted newest-first, each entry containing id, title, \
                ISO-8601 date, durationSeconds, language, hasSummary, and tags. \
                Pass an optional `query` to substring-match the title, and \
                optional `tags` to require all listed tags.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional case-insensitive substring filter on transcript title.")
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "description": .string("Optional tag names; a transcript must contain all listed tags."),
                        "items": .object([
                            "type": .string("string")
                        ])
                    ])
                ])
            ]),
            annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "list_tags",
            description: "List available transcript tags with their color and usage count.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_transcript",
            description: "Return the full markdown transcript for the given id (as listed by list_transcripts).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Transcript id from list_transcripts.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "get_summary",
            description: """
                Return the LLM-generated summary, generation model and \
                timestamp for the given transcript id. Returns an error \
                result if the transcript hasn't been summarized yet.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Transcript id from list_transcripts.")
                    ])
                ]),
                "required": .array([.string("id")])
            ]),
            annotations: Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "set_tags",
            description: """
                Replace the full tag set for a transcript. Unknown tag names \
                are created automatically in the managed catalog. To add or \
                remove one tag incrementally, read the current tags first and \
                send the complete replacement list.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("Transcript id from list_transcripts.")
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "description": .string("Complete replacement list of tag names."),
                        "items": .object([
                            "type": .string("string")
                        ])
                    ])
                ]),
                "required": .array([.string("id"), .string("tags")])
            ]),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        )
    ]

    // MARK: - Dispatch

    static func handle(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        switch name {
        case "list_transcripts":
            let tags = arguments?["tags"]?.arrayValue?.compactMap { $0.stringValue }
            return listTranscripts(query: arguments?["query"]?.stringValue, tags: tags)
        case "list_tags":
            return listTags()
        case "get_transcript":
            return getTranscript(id: arguments?["id"]?.stringValue)
        case "get_summary":
            return getSummary(id: arguments?["id"]?.stringValue)
        case "set_tags":
            let tags = arguments?["tags"]?.arrayValue?.compactMap { $0.stringValue }
            return await setTags(id: arguments?["id"]?.stringValue, tags: tags)
        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool implementations

    private static func listTranscripts(query: String?, tags: [String]?) -> CallTool.Result {
        let docs: [TranscriptDocument]
        do {
            docs = try TranscriptStore.shared.loadAll()
        } catch {
            return errorResult("Failed to read transcripts: \(error.localizedDescription)")
        }

        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requestedTags = normalizedTags(tags ?? [])
        let filtered = docs
            .filter { doc in
                let matchesQuery = needle?.isEmpty != false || doc.title.lowercased().contains(needle!)
                let docTags = Set(doc.tags.map { TagStore.key(for: $0) })
                let matchesTags = requestedTags.allSatisfy { docTags.contains($0) }
                return matchesQuery && matchesTags
            }
            .sorted { $0.date > $1.date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let payload: [[String: Any]] = filtered.map { doc in
            [
                "id": doc.id,
                "title": doc.title,
                "date": iso.string(from: doc.date),
                "durationSeconds": Int(doc.duration.rounded()),
                "language": doc.language.rawValue,
                "hasSummary": (doc.summary?.isEmpty == false),
                "tags": doc.tags
            ]
        }
        return jsonResult(payload, fallback: "Failed to encode transcript list.")
    }

    private static func listTags() -> CallTool.Result {
        let catalog: [Tag]
        let docs: [TranscriptDocument]
        do {
            catalog = try TagStore.shared.loadAll()
            docs = try TranscriptStore.shared.loadAll()
        } catch {
            return errorResult("Failed to read tags: \(error.localizedDescription)")
        }

        let catalogByKey = Dictionary(
            uniqueKeysWithValues: catalog.map { (TagStore.key(for: $0.name), $0) }
        )
        var counts: [String: Int] = [:]
        var firstSeenName: [String: String] = [:]
        for doc in docs {
            for tagName in doc.tags {
                let clean = TagStore.cleanName(tagName)
                let key = TagStore.key(for: clean)
                guard !key.isEmpty else { continue }
                counts[key, default: 0] += 1
                firstSeenName[key] = firstSeenName[key] ?? clean
            }
        }

        let allKeys = Set(catalogByKey.keys).union(counts.keys)
        let payload: [[String: Any]] = allKeys.map { key in
            let tag = catalogByKey[key]
            return [
                "name": tag?.name ?? firstSeenName[key] ?? key,
                "color": (tag?.color ?? .gray).rawValue,
                "count": counts[key] ?? 0
            ]
        }
        .sorted {
            let leftCount = $0["count"] as? Int ?? 0
            let rightCount = $1["count"] as? Int ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let leftName = $0["name"] as? String ?? ""
            let rightName = $1["name"] as? String ?? ""
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }

        return jsonResult(payload, fallback: "Failed to encode tag list.")
    }

    private static func getTranscript(id: String?) -> CallTool.Result {
        guard let id, !id.isEmpty else {
            return errorResult("Missing required argument: id")
        }
        let url = TranscriptStore.shared.rootURL.appendingPathComponent("\(id).md")
        guard let data = try? Data(contentsOf: url),
              let markdown = String(data: data, encoding: .utf8) else {
            return errorResult("No transcript found for id: \(id)")
        }
        return CallTool.Result(content: [.text(text: markdown, annotations: nil, _meta: nil)], isError: false)
    }

    private static func getSummary(id: String?) -> CallTool.Result {
        guard let id, !id.isEmpty else {
            return errorResult("Missing required argument: id")
        }
        let docURL = TranscriptStore.shared.rootURL.appendingPathComponent("\(id).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: docURL),
              let doc = try? decoder.decode(TranscriptDocument.self, from: data) else {
            return errorResult("No transcript found for id: \(id)")
        }
        guard let summary = doc.summary, !summary.isEmpty else {
            return errorResult("Transcript \(id) has no summary yet.")
        }

        var rendered = "# Summary\n\n\(summary)\n"
        if let model = doc.summaryModelShortName {
            rendered += "\n_Model: \(model)"
            if let generatedAt = doc.summaryGeneratedAt {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime]
                rendered += " · Generated \(f.string(from: generatedAt))"
            }
            rendered += "_\n"
        }
        return CallTool.Result(content: [.text(text: rendered, annotations: nil, _meta: nil)], isError: false)
    }

    private static func setTags(id: String?, tags: [String]?) async -> CallTool.Result {
        guard let id, !id.isEmpty else {
            return errorResult("Missing required argument: id")
        }
        guard let tags else {
            return errorResult("Missing required argument: tags")
        }

        let outcome = await MainActor.run { () -> SetTagsOutcome in
            guard let app = AppState.shared else { return .appUnavailable }
            guard app.transcripts.contains(where: { $0.id == id }) else { return .unknownID }
            app.setTags(tags, for: id)
            let updated = app.transcripts.first(where: { $0.id == id })?.tags ?? []
            return .success(updated)
        }

        switch outcome {
        case .success(let updated):
            return jsonResult(
                ["id": id, "tags": updated],
                fallback: "Failed to encode updated tag list."
            )
        case .appUnavailable:
            return errorResult("Meeting Transcriber app state is unavailable.")
        case .unknownID:
            return errorResult("No transcript found for id: \(id)")
        }
    }

    // MARK: - Helpers

    private enum SetTagsOutcome {
        case success([String])
        case appUnavailable
        case unknownID
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in tags {
            let key = TagStore.key(for: tag)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(key)
        }
        return result
    }

    private static func jsonResult(_ object: Any, fallback: String) -> CallTool.Result {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return errorResult(fallback)
        }
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
