import Foundation

/// Storage seam for user preferences (repo rule: storage behind a protocol,
/// local today, cloud-syncable later). The app talks to this, never to a file.
protocol SettingsStore: AnyObject {
    /// Dock-style auto-hide for the floating bar.
    var barAutoHide: Bool { get set }
}

/// Local, file-backed settings under Application Support. Persisted JSON carries
/// a `schemaVersion` from day one to drive future migrations; an unreadable or
/// mismatched file falls back to defaults rather than failing.
final class LocalSettingsStore: SettingsStore {
    static let shared = LocalSettingsStore()

    private struct File: Codable {
        var schemaVersion: Int
        var barAutoHide: Bool
    }

    private static let schemaVersion = 1
    private static let defaults = File(schemaVersion: schemaVersion, barAutoHide: false)

    private let url: URL
    private var file: File

    init(url: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Talkeo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = url ?? dir.appendingPathComponent("settings.json")
        self.file = LocalSettingsStore.read(from: self.url)
    }

    var barAutoHide: Bool {
        get { file.barAutoHide }
        set {
            guard file.barAutoHide != newValue else { return }
            file.barAutoHide = newValue
            write()
        }
    }

    private static func read(from url: URL) -> File {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.schemaVersion == schemaVersion else { return defaults }
        return file
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
