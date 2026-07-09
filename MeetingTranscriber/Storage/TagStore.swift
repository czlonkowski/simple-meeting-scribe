import Foundation

final class TagStore {
    static let shared = TagStore()

    private var catalogURL: URL {
        TranscriptStore.shared.rootURL.appendingPathComponent("tags.json")
    }

    private init() {}

    func loadAll() throws -> [Tag] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: catalogURL.path) else { return [] }
        let data = try Data(contentsOf: catalogURL)
        let decoded = try JSONDecoder().decode([Tag].self, from: data)
        return sortedTags(deduped(decoded))
    }

    func save(_ tags: [Tag]) throws {
        try FileManager.default.createDirectory(
            at: TranscriptStore.shared.rootURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sortedTags(deduped(tags)))
        try data.write(to: catalogURL, options: [.atomic])
    }

    func ensure(names: [String]) throws -> [Tag] {
        var tags = try loadAll()
        var knownKeys = Set(tags.map { Self.key(for: $0.name) })
        var changed = false

        for rawName in names {
            let name = Self.cleanName(rawName)
            guard !name.isEmpty else { continue }
            let key = Self.key(for: name)
            guard !knownKeys.contains(key) else { continue }

            let color = TagColor.allCases[tags.count % TagColor.allCases.count]
            tags.append(Tag(name: name, color: color))
            knownKeys.insert(key)
            changed = true
        }

        if changed {
            try save(tags)
        }
        return sortedTags(tags)
    }

    static func cleanName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func key(for name: String) -> String {
        cleanName(name).lowercased()
    }

    private func deduped(_ tags: [Tag]) -> [Tag] {
        var seen: Set<String> = []
        var result: [Tag] = []
        for tag in tags {
            let name = Self.cleanName(tag.name)
            guard !name.isEmpty else { continue }
            let key = Self.key(for: name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(Tag(name: name, color: tag.color))
        }
        return result
    }

    private func sortedTags(_ tags: [Tag]) -> [Tag] {
        tags.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
