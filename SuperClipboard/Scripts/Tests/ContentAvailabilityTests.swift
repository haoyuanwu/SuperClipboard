import AppKit
import Foundation

@main
struct ContentAvailabilityTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Availability-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "SuperClipboard.AvailabilityTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let source = root.appendingPathComponent("source.txt")
        let remaining = root.appendingPathComponent("remaining.txt")
        let restored = root.appendingPathComponent("restored.txt")
        let missing = root.appendingPathComponent("missing.txt")
        try Data("source".utf8).write(to: source)
        try Data("remaining".utf8).write(to: remaining)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = bitmap.representation(using: .png, properties: [:])!
        try image.write(to: root.appendingPathComponent("saved.png"))
        try image.write(to: root.appendingPathComponent("thumb.png"))
        func item(_ kind: EntryKind, text: String? = nil, paths: [URL] = [], payload: String? = nil,
                  thumbnail: String? = nil, pinned: Bool = false) -> ClipboardEntry {
            ClipboardEntry(id: UUID(), kind: kind, fingerprint: UUID().uuidString, plainText: text,
                filePaths: paths.map(\.path), payloadName: payload, thumbnailName: thumbnail,
                sourceAppName: "Availability Tests", sourceBundleID: nil,
                createdAt: Date(), lastCopiedAt: Date(), copyCount: 1, isPinned: pinned)
        }
        let original = item(.file, paths: [source])
        let partial = item(.file, paths: [missing, remaining])
        let saved = item(.image, paths: [missing], payload: "saved.png")
        let video = item(.video, paths: [missing], thumbnail: "thumb.png")
        let stalePicture = item(.image, paths: [missing], thumbnail: "thumb.png")
        let pinned = item(.file, paths: [missing], pinned: true)
        let restoredItem = item(.file, paths: [restored])
        let text = item(.text, text: "Retained plain text", payload: "missing.rtf")
        let empty = item(.text)
        let records = [original, partial, saved, video, stalePicture, pinned, restoredItem, text, empty]
        let index = root.appendingPathComponent("history.json")
        try JSONEncoder().encode(records).write(to: index)
        let store = ClipboardStore(storageDirectory: root, defaults: defaults,
                                   pasteboard: pasteboard, observesPasteboard: false)
        store.addToNotebook(original)
        try await settle(store)
        store.addToTransfer(original)
        try await settle(store)
        try fm.removeItem(at: source)
        await store.refreshAvailability()
        precondition(store.contentAvailability(for: original).isMissing)
        precondition(store.contentAvailability(for: partial).isPartial)
        precondition(!store.contentAvailability(for: saved).isMissing)
        precondition(store.contentAvailability(for: video).isMissing, "Thumbnail alone cannot restore a video")
        precondition(store.contentAvailability(for: stalePicture).isMissing)
        precondition(!store.contentAvailability(for: text).isMissing, "Missing RTF falls back to plain text")
        precondition(!store.contentAvailability(for: store.notebookEntries[0]).isMissing)
        precondition(!store.contentAvailability(for: store.transferEntries[0]).isMissing)

        pasteboard.clearContents()
        pasteboard.setString("Keep existing clipboard", forType: .string)
        let change = pasteboard.changeCount
        precondition(!store.copy(original) && pasteboard.changeCount == change)
        precondition(pasteboard.string(forType: .string) == "Keep existing clipboard")
        precondition(store.entryDragProvider(for: video) == nil)
        precondition(store.copy(partial), "A partial file group can still copy its remaining files")
        let copied = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        precondition(copied == [remaining])
        let provider = store.entryDragProvider(for: partial)!
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
        precondition(url == remaining)

        // Files restored after a scan must survive the cleanup's fresh check.
        try Data("restored".utf8).write(to: restored)
        let backup = root.appendingPathComponent("history-backup.json")
        try fm.moveItem(at: index, to: backup)
        try fm.createDirectory(at: index, withIntermediateDirectories: false)
        store.cleanUnavailable(in: .history)
        precondition(store.entries.count == records.count && store.availabilityError != nil,
                     "A failed index write must preserve records and attachments")
        try fm.removeItem(at: index)
        try fm.moveItem(at: backup, to: index)
        store.cleanUnavailable(in: .history)
        precondition(Set(store.entries.map(\.id)) == Set([partial.id, saved.id, pinned.id, restoredItem.id, text.id]))
        precondition(store.notebookEntries.count == 1 && store.transferEntries.count == 1)
        precondition(fm.fileExists(atPath: remaining.path) && fm.fileExists(atPath: restored.path))
        precondition(fm.fileExists(atPath: root.appendingPathComponent("saved.png").path))
        let transfer = store.transferEntries[0]
        try fm.removeItem(at: transfer.firstFileURL!)
        await store.refreshAvailability()
        precondition(store.unavailableCount(in: .transfer) == 1)
        store.cleanUnavailable(in: .transfer)
        precondition(store.transferEntries.isEmpty && store.notebookEntries.count == 1)
        precondition(fm.fileExists(atPath: store.notebookEntries[0].filePaths[0]))
        let reopened = ClipboardStore(storageDirectory: root, defaults: defaults,
                                      pasteboard: pasteboard, observesPasteboard: false)
        precondition(Set(reopened.entries.map(\.id)) == Set(store.entries.map(\.id)))
        print("PASS: missing/partial/restored files, saved-image fallback, thumbnail-only loss, safe clipboard, filtered copy/drag, pinned/notebook protection, cleanup persistence and failed-write rollback")
    }

    @MainActor static func settle(_ store: ClipboardStore) async throws {
        for _ in 0..<500 {
            if !store.notebookBusy && !store.transferBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Archive timed out")
    }
}
