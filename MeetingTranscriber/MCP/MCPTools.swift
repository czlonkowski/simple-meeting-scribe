import Foundation
import MCP

/// Tool catalog and dispatcher for the local MCP server. Exposes three
/// read-only tools backed by `TranscriptStore` so an external MCP client
/// (Claude Code, etc.) can browse transcripts without touching the app's
/// internal state.
enum MCPTools {

    // MARK: - Definitions

    static let definitions: [Tool] = [
        Tool(
            name: "list_transcripts",
            description: """
                List transcripts stored by Meeting Transcriber. Returns a JSON \
                array sorted newest-first, each entry containing id, title, \
                ISO-8601 date, durationSeconds, language, and hasSummary. \
                Pass an optional `query` to substring-match the title.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Optional case-insensitive substring filter on transcript title.")
                    ])
                ])
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
                Return the LLM-generated summary, action items, generation \
                model and timestamp for the given transcript id. Returns an \
                error result if the transcript hasn't been summarized yet.
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
        )
    ]

    // MARK: - Dispatch

    static func handle(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        switch name {
        case "list_transcripts":
            return listTranscripts(query: arguments?["query"]?.stringValue)
        case "get_transcript":
            return getTranscript(id: arguments?["id"]?.stringValue)
        case "get_summary":
            return getSummary(id: arguments?["id"]?.stringValue)
        default:
            return errorResult("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool implementations

    private static func listTranscripts(query: String?) -> CallTool.Result {
        let docs: [TranscriptDocument]
        do {
            docs = try TranscriptStore.shared.loadAll()
        } catch {
            return errorResult("Failed to read transcripts: \(error.localizedDescription)")
        }

        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = docs
            .filter { needle?.isEmpty != false || $0.title.lowercased().contains(needle!) }
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
                "hasSummary": (doc.summary?.isEmpty == false)
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return errorResult("Failed to encode transcript list.")
        }
        return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
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
        if let items = doc.actionItems, !items.isEmpty {
            rendered += "\n## Action items\n\n"
            for item in items {
                rendered += "- \(item)\n"
            }
        }
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

    // MARK: - Helpers

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}
