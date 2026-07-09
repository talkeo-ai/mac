import Foundation

/// One past Listen text the user can replay. No target/translation — Listen
/// just speaks the text back, so the entry is the text itself plus its
/// detected language.
struct ListenHistoryEntry: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let detectedLang: String
    let timestamp: Date
}

/// Storage seam for Listen history (same shape as `HistoryStore`: local today,
/// cloud-syncable later).
protocol ListenHistoryStore {
    func all() -> [ListenHistoryEntry]
    func add(_ entry: ListenHistoryEntry)
    func remove(id: String)
    func clear()
}

/// Local, file-backed history under Application Support, mirroring
/// `LocalHistoryStore`. Persisted JSON carries a `schemaVersion` from day one.
final class LocalListenHistoryStore: ListenHistoryStore {
    static let shared = LocalListenHistoryStore()

    private struct File: Codable {
        var schemaVersion: Int
        var entries: [ListenHistoryEntry]
    }

    private static let schemaVersion = 1
    private static let maxEntries = 50

    private let url: URL
    private var entries: [ListenHistoryEntry]

    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Talkeo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("listen-history.json")
        self.entries = LocalListenHistoryStore.read(from: self.url)
    }

    func all() -> [ListenHistoryEntry] { entries }

    func add(_ entry: ListenHistoryEntry) {
        // Collapse repeats: replaying the same text jumps it to the top.
        let key = entry.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        entries.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
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

    private static func read(from url: URL) -> [ListenHistoryEntry] {
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
