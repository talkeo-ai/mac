import Foundation

/// Apps where text selection should never trigger a tooltip — media/consumption
/// apps whose selectable strings (song titles, captions, metadata) are not things
/// the user means to act on. Consulted *before* any strategy runs, so excluded
/// apps never receive a synthetic Cmd+C.
///
/// `schemaVersion` is carried from day 1 (repo rule) so a future user-editable
/// settings file can be migrated without a format break — but we are NOT building
/// a settings system now (scope creep). Today the list is a hardcoded default;
/// the `init(bundleIDs:)` initializer is the single seam a future settings layer
/// will feed.
struct AppExclusionList {
    static let schemaVersion = 1

    /// Default excluded bundle identifiers (media / consumption apps).
    static let defaultBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.apple.TV",
        "com.apple.QuickTimePlayerX",
        "com.apple.podcasts",
        "com.spotify.client",
    ]

    private let bundleIDs: Set<String>

    init(bundleIDs: Set<String> = AppExclusionList.defaultBundleIDs) {
        self.bundleIDs = Set(bundleIDs.map { $0.lowercased() })
    }

    func isExcluded(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID.lowercased())
    }
}
