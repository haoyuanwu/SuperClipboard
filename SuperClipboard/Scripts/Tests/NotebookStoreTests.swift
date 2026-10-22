import AppKit
import Foundation

@main
struct NotebookStoreTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NotebookStoreTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "SuperClipboard.NotebookTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let history = root.appendingPathComponent("History")
        let originals = root.appendingPathComponent("Originals")
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            .representation(using: .png, properties: [:])!
        try png.write(to: history.appendingPathComponent("image.png"))
        try png.write(to: history.appendingPathComponent("thumb.png"))
        let rich = NSAttributedString(string: "Notebook test", attributes: [.foregroundColor: NSColor.blue])
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
        try rtf.write(to: history.appendingPathComponent("text.rtf"))
        let file = originals.appendingPathComponent("report.txt")
        let video = originals.appendingPathComponent("movie.mov")
        try Data("original file".utf8).write(to: file)
        try Data("original video".utf8).write(to: video)
        func entry(_ kind: EntryKind, text: String? = nil, paths: [String] = [], payload: String? = nil, thumbnail: String? = nil) -> ClipboardEntry {
            ClipboardEntry(id: UUID(), kind: kind, fingerprint: kind.rawValue, plainText: text,
                filePaths: paths, payloadName: payload, thumbnailName: thumbnail,
                sourceAppName: "Notebook Tests", sourceBundleID: nil, createdAt: Date(),
                lastCopiedAt: Date(), copyCount: 1, isPinned: false)
        }
        var records = [entry(.text, text: "Notebook test", payload: "text.rtf"),
                       entry(.image, paths: [originals.appendingPathComponent("deleted.png").path], payload: "image.png"),
                       entry(.file, paths: [file.path]), entry(.video, paths: [video.path], thumbnail: "thumb.png")]
        let now = Date()
        for index in records.indices {
            records[index].createdAt = now.addingTimeInterval(Double(-index * 60))
            records[index].lastCopiedAt = now.addingTimeInterval(Double(index * 60))
        }
        try JSONEncoder().encode(records).write(to: history.appendingPathComponent("history.json"))
        let store = ClipboardStore(storageDirectory: history, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        precondition(store.sortOrder == .recent, "Default sorting must be chronological")
        precondition(ClipboardSortOrder(storedValue: "最近复制") == .recent)
        precondition(ClipboardSortOrder(storedValue: "复制次数") == .frequency)
        precondition(store.sortedEntries.map(\.id) == records.map(\.id), "Time sorting must use first creation, not last copy")
        precondition(store.copy(records[3]))
        precondition(store.sortedEntries.map(\.id) == records.map(\.id), "Copying must not change first-time order")
        store.sortOrder = .frequency
        var session = ClipboardListSession()
        session.begin(with: store.sortedEntries)
        let openingOrder = session.orderedIDs
        for _ in 0..<3 { precondition(store.copy(records[2])) }
        let live = session.entries(from: store.sortedEntries)
        precondition(live.map(\.id) == openingOrder, "An open list must not jump when copy counts change")
        precondition(live.first { $0.id == records[2].id }?.copyCount == 4, "Displayed counts must stay current")
        precondition(store.sortedEntries.first?.id == records[2].id)
        session.begin(with: store.sortedEntries)
        precondition(session.orderedIDs.first == records[2].id, "Reopening must apply the latest sorting")
        var incoming = records[0]
        incoming.id = UUID()
        let appended = session.entries(from: [incoming] + store.sortedEntries)
        precondition(appended.last?.id == incoming.id, "New content must not shuffle existing rows")
        session.includeNewEntries(from: [incoming] + store.sortedEntries)
        var another = incoming
        another.id = UUID()
        session.includeNewEntries(from: [another, incoming] + store.sortedEntries)
        let updatedNewItems = session.entries(from: [incoming, another] + store.sortedEntries)
        precondition(updatedNewItems.suffix(2).map(\.id) == [incoming.id, another.id], "Newly added rows must keep their positions after later copies")
        precondition(session.entries(from: []).isEmpty, "Deleted items must not remain in the snapshot")
        store.sortOrder = .recent
        for record in records {
            store.addToNotebook(record)
            try await finish(store)
            precondition(store.notebookError == nil)
        }
        precondition(store.notebookEntries.count == 4)
        store.addToNotebook(records[0])
        precondition(!store.notebookBusy && store.notebookEntries.count == 4, "Adding twice must not duplicate a record")
        store.clearUnpinned()
        try fm.removeItem(at: originals)
        precondition(store.entries.isEmpty && store.notebookEntries.count == 4, "History cleanup must not remove notebook data")
        for record in store.notebookEntries {
            precondition(store.copy(record), "Archived data must copy after its source is gone")
            switch record.kind {
            case .text:
                precondition(pasteboard.string(forType: .string) == "Notebook test")
                precondition(store.richText(for: record)?.string == "Notebook test")
                let preview = await store.loadListPreview(for: record, request: store.listPreviewRequest(for: record))
                precondition(preview?.lightText?.string == "Notebook test")
            case .image:
                precondition(store.thumbnail(for: record) != nil)
                let preview = await store.loadListPreview(for: record, request: store.listPreviewRequest(for: record))
                precondition(preview?.image != nil)
            case .file, .video:
                precondition(fm.fileExists(atPath: record.filePaths[0]))
                precondition(!record.filePaths[0].hasPrefix(originals.path))
            }
        }
        let restarted = ClipboardStore(storageDirectory: history, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        precondition(restarted.notebookEntries.count == 4, "Notebook must survive app restart")
        restarted.sortOrder = .frequency
        _ = restarted.sortedNotebookEntries
        let copied = restarted.notebookEntries.first { $0.kind == .text }!
        precondition(restarted.copy(copied) && restarted.copy(copied))
        precondition(restarted.sortedNotebookEntries.first?.id == copied.id, "Copy counts must invalidate cached sorting")
        let pinned = restarted.notebookEntries.first { $0.kind == .file }!
        restarted.togglePin(pinned)
        precondition(restarted.sortedNotebookEntries.first?.id == pinned.id, "Pinning must invalidate cached sorting")
        restarted.togglePin(pinned)
        precondition(restarted.sortedNotebookEntries.first?.id == copied.id)
        let old = restarted.notebookDirectory
        let destination = root.appendingPathComponent("Custom Notebook")
        restarted.changeNotebookDirectory(to: destination)
        try await finish(restarted)
        precondition(restarted.notebookError == nil && restarted.notebookDirectory.path == destination.path)
        precondition(!fm.fileExists(atPath: old.path))
        for item in restarted.notebookEntries {
            for path in item.filePaths { precondition(path.hasPrefix(destination.path) && fm.fileExists(atPath: path)) }
            precondition(restarted.copy(item))
        }
        let migrated = ClipboardStore(storageDirectory: history, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        precondition(migrated.notebookDirectory.path == destination.path && migrated.notebookEntries.count == 4)
        let existing = root.appendingPathComponent("Existing")
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        migrated.changeNotebookDirectory(to: existing)
        try await finish(migrated)
        precondition(migrated.notebookError != nil && migrated.notebookDirectory.path == destination.path)
        migrated.notebookError = nil
        let missing = entry(.file, paths: [root.appendingPathComponent("missing.txt").path])
        // Use another fingerprint so this exercises missing-source handling.
        var newMissing = missing
        newMissing.fingerprint = "missing"
        migrated.addToNotebook(newMissing)
        try await finish(migrated)
        precondition(migrated.notebookError != nil && migrated.notebookEntries.count == 4)
        let brokenIndex = destination.appendingPathComponent("notebook.json")
        let invalid = Data("invalid index".utf8)
        try invalid.write(to: brokenIndex)
        let broken = ClipboardStore(storageDirectory: history, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        broken.addToNotebook(records[0])
        precondition(!broken.notebookBusy && broken.notebookError != nil)
        let unchanged = try Data(contentsOf: brokenIndex)
        precondition(unchanged == invalid, "An unreadable index must never be overwritten")
        print("PASS: all content types, source deletion, history cleanup, deduplication, copy, restart, migration, rollback and index protection")
    }

    @MainActor static func finish(_ store: ClipboardStore) async throws {
        for _ in 0..<500 {
            if !store.notebookBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Notebook operation timed out")
    }
}
