import Foundation

/// Retain positions while a window is open, but always display current values.
struct ClipboardListSession {
    private(set) var orderedIDs: [UUID] = []

    mutating func begin(with entries: [ClipboardEntry]) {
        orderedIDs = entries.map(\.id)
    }

    mutating func includeNewEntries(from entries: [ClipboardEntry]) {
        let current = Set(entries.map(\.id))
        let known = Set(orderedIDs)
        orderedIDs = orderedIDs.filter { current.contains($0) } + entries.filter { !known.contains($0.id) }.map(\.id)
    }

    func entries(from currentEntries: [ClipboardEntry]) -> [ClipboardEntry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        let known = Set(orderedIDs)
        let ordered = orderedIDs.compactMap { entriesByID[$0] }
            + currentEntries.filter { !known.contains($0.id) }
        // Explicit pin/unpin actions still take effect without reordering peers.
        return ordered.filter(\.isPinned) + ordered.filter { !$0.isPinned }
    }
}
