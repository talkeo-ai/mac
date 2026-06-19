import AppKit

/// Testability seam over `NSPasteboard`. Lets `PasteboardCopyService` run its
/// race-safe copy/restore logic against a fake in unit tests without touching
/// the real system pasteboard.
protocol PasteboardProtocol: AnyObject {
    var changeCount: Int { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func availableTypes() -> [NSPasteboard.PasteboardType]
    func snapshotItems() -> [[NSPasteboard.PasteboardType: Data]]
    func restore(items: [[NSPasteboard.PasteboardType: Data]])
}

extension NSPasteboard: PasteboardProtocol {
    func availableTypes() -> [NSPasteboard.PasteboardType] { types ?? [] }

    /// Captures every item and every type currently on the pasteboard.
    /// Best-effort: promise providers (lazy data) are not guaranteed to survive.
    func snapshotItems() -> [[NSPasteboard.PasteboardType: Data]] {
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            captured.append(dict)
        }
        return captured
    }

    /// Rewrites the pasteboard from a previously captured snapshot.
    func restore(items: [[NSPasteboard.PasteboardType: Data]]) {
        clearContents()
        let pbItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if !pbItems.isEmpty {
            writeObjects(pbItems)
        }
    }
}
