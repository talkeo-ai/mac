import Foundation

/// One past rewrite the user can revisit. Carries the full structured result
/// (changes included) so re-opening restores the diff and its teaching cards
/// without re-hitting the API.
struct ImproveHistoryEntry: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let improved: String
    let changes: [ImproveResult.Change]
    let timestamp: Date
}

/// Storage seam for improve history (repo rule: storage behind a protocol,
/// local today, cloud-syncable later). The UI talks to this, never to a file.
protocol ImproveHistoryStore {
    func all() -> [ImproveHistoryEntry]
    func add(_ entry: ImproveHistoryEntry)
    func remove(id: String)
    func clear()
}

/// Local, file-backed improve history under Application Support. Persisted JSON
/// carries a `schemaVersion` from day one to drive future migrations.
final class LocalImproveHistoryStore: ImproveHistoryStore {
    static let shared = LocalImproveHistoryStore()

    private struct File: Codable {
        var schemaVersion: Int
        var entries: [ImproveHistoryEntry]
    }

    private static let schemaVersion = 1
    private static let maxEntries = 50

    private let url: URL
    private var entries: [ImproveHistoryEntry]

    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Talkeo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("improve-history.json")
        self.entries = LocalImproveHistoryStore.read(from: self.url)
    }

    func all() -> [ImproveHistoryEntry] { entries }

    func add(_ entry: ImproveHistoryEntry) {
        // Collapse repeats: re-improving the same text jumps to the top.
        let key = entry.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        entries.removeAll { $0.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries = Array(entries.prefix(Self.maxEntries)) }
        write()
    }

    func remove(id: String) {
        entries.removeAll { $0.id == id }
        write()
    }

    func clear() {
        entries = []
        write()
    }

    private static func read(from url: URL) -> [ImproveHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(File.self, from: data),
              file.schemaVersion == schemaVersion else { return [] }
        return file.entries
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(File(schemaVersion: Self.schemaVersion, entries: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
