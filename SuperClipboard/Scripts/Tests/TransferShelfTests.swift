import AppKit
import Foundation
import UniformTypeIdentifiers

@main
struct TransferShelfTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TransferShelfTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "SuperClipboard.TransferTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let originals = root.appendingPathComponent("Originals")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        try image.write(to: root.appendingPathComponent("image.png"))
        try image.write(to: root.appendingPathComponent("thumb.png"))
        let rich = NSAttributedString(string: "Transfer rich text", attributes: [.foregroundColor: NSColor.blue])
        try rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
            .write(to: root.appendingPathComponent("text.rtf"))
        let file = originals.appendingPathComponent("file.txt")
        let video = originals.appendingPathComponent("video.mov")
        try Data("file bytes".utf8).write(to: file)
        try Data("video bytes".utf8).write(to: video)
        func entry(_ kind: EntryKind, text: String? = nil, paths: [String] = [], payload: String? = nil, thumbnail: String? = nil) -> ClipboardEntry {
            ClipboardEntry(id: UUID(), kind: kind, fingerprint: UUID().uuidString, plainText: text,
                filePaths: paths, payloadName: payload, thumbnailName: thumbnail, sourceAppName: "Transfer Tests",
                sourceBundleID: nil, createdAt: Date(), lastCopiedAt: Date(), copyCount: 1, isPinned: false)
        }
        let records = [entry(.text, text: rich.string, payload: "text.rtf"),
                       entry(.image, payload: "image.png"), entry(.file, paths: [file.path]),
                       entry(.video, paths: [video.path], thumbnail: "thumb.png")]
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("history.json"))
        let store = ClipboardStore(storageDirectory: root, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        precondition(store.transferClearMinutes == 10)
        store.transferWindowDidOpen()
        for record in records {
            store.addToTransfer(record)
            try await finish { store.transferBusy }
            precondition(store.transferError == nil)
        }
        precondition(store.transferEntries.count == 4)
        store.addToTransfer(records[0])
        precondition(!store.transferBusy && store.transferEntries.count == 4)
        // Existing entries may use historical path fingerprints; content imports
        // must still recognize the same plain text or image bytes.
        store.addDroppedImageToTransfer(image)
        try await finish { store.transferBusy }
        store.addDroppedTextToTransfer(rich.string)
        try await finish { store.transferBusy }
        precondition(store.transferEntries.count == 4)
        let stagedText = store.transferEntries.first { $0.kind == .text }!
        let richDragProvider = store.transferDragProvider(for: stagedText)!
        precondition(richDragProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        precondition(richDragProvider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier))
        store.addToNotebook(stagedText)
        try await finish { store.notebookBusy }
        precondition(store.notebookError == nil && store.notebookEntries.count == 1)
        precondition(store.notebookEntries[0].transferFolderName == nil)
        precondition(fm.fileExists(atPath: root.appendingPathComponent("text.rtf").path), "Saving a transfer entry to notebook must not remove history attachments")
        store.clearUnpinned()
        try fm.removeItem(at: originals)
        for item in store.transferEntries {
            precondition(item.isTransferEntry && !item.isNotebookEntry)
            precondition(store.copy(item), "Transfer copies must survive original/history cleanup")
            if item.kind == .text { precondition(store.richText(for: item)?.string == rich.string) }
            if item.kind == .image {
                let preview = await store.loadListPreview(for: item, request: store.listPreviewRequest(for: item))
                precondition(preview?.image != nil)
            }
        }
        let closed = Date()
        store.transferWindowDidClose(at: closed)
        precondition(!store.clearExpiredTransfer(at: closed.addingTimeInterval(599)))
        store.transferWindowDidOpen(at: closed.addingTimeInterval(300))
        precondition(store.transferClosedAt == nil && !store.clearExpiredTransfer(at: closed.addingTimeInterval(1200)))
        store.transferWindowDidClose(at: closed)
        let stagedDirectories = store.transferEntries.map { root.appendingPathComponent("Transfer").appendingPathComponent($0.transferFolderName!) }
        precondition(store.clearExpiredTransfer(at: closed.addingTimeInterval(600)))
        precondition(store.transferEntries.isEmpty && store.notebookEntries.count == 1)
        precondition(store.copy(store.notebookEntries[0]), "Expiry must not remove notebook data")
        try await finish { stagedDirectories.contains { fm.fileExists(atPath: $0.path) } }

        let note = entry(.text, text: "Temporary note")
        store.transferWindowDidOpen()
        store.addToTransfer(note)
        try await finish { store.transferBusy }
        store.transferWindowDidClose()
        let restarted = ClipboardStore(storageDirectory: root, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        precondition(restarted.transferEntries.count == 1 && restarted.transferClosedAt != nil)
        restarted.transferWindowDidOpen()
        precondition(restarted.transferClosedAt == nil)
        restarted.transferWindowDidClose(at: closed)
        restarted.transferClearMinutes = 1
        precondition(restarted.clearExpiredTransfer(at: closed.addingTimeInterval(60)))
        restarted.transferClearMinutes = 0
        precondition(restarted.transferClearMinutes == 1)
        restarted.transferClearMinutes = 2000
        precondition(restarted.transferClearMinutes == 1440)
        restarted.transferClearMinutes = 10
        restarted.transferWindowDidOpen()
        restarted.addToTransfer(entry(.text, text: "Expires on reopen"))
        try await finish { restarted.transferBusy }
        restarted.transferWindowDidClose(at: closed)
        restarted.transferWindowDidOpen(at: closed.addingTimeInterval(601))
        precondition(restarted.transferEntries.isEmpty, "Opening after expiry must clear before canceling the deadline")
        let missing = entry(.file, paths: [root.appendingPathComponent("missing.txt").path])
        restarted.addToTransfer(missing)
        try await finish { restarted.transferBusy }
        precondition(restarted.transferEntries.isEmpty && restarted.transferError != nil)
        restarted.transferError = nil
        restarted.addToTransfer(entry(.text, text: "Close during save"))
        restarted.transferWindowDidClose(at: Date().addingTimeInterval(-601))
        try await finish { restarted.transferBusy }
        precondition(restarted.transferEntries.isEmpty, "A save finishing after the deadline must not leave expired data")
        restarted.transferWindowDidOpen()
        restarted.addToTransfer(entry(.text, text: "Expired after restart"))
        try await finish { restarted.transferBusy }
        let index = root.appendingPathComponent("Transfer/transfer.json")
        struct SavedState: Encodable {
            let entries: [ClipboardEntry]
            let closedAt: Date
        }
        try JSONEncoder().encode(SavedState(entries: restarted.transferEntries, closedAt: Date().addingTimeInterval(-601)))
            .write(to: index, options: .atomic)
        let expired = ClipboardStore(storageDirectory: root, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        precondition(expired.transferEntries.isEmpty, "Expired data must be cleared at app startup")
        let invalid = Data("invalid".utf8)
        try invalid.write(to: index)
        let broken = ClipboardStore(storageDirectory: root, defaults: defaults, pasteboard: pasteboard, observesPasteboard: false)
        broken.transferWindowDidOpen()
        broken.addToTransfer(note)
        precondition(broken.transferError != nil && !broken.transferBusy)
        let preserved = try Data(contentsOf: index)
        precondition(preserved == invalid)

        let dropRoot = root.appendingPathComponent("DropTests")
        try fm.createDirectory(at: dropRoot, withIntermediateDirectories: true)
        let dropStore = ClipboardStore(storageDirectory: dropRoot, defaults: defaults,
                                       pasteboard: pasteboard, observesPasteboard: false)
        precondition(!dropStore.transferDropSavesHistory)
        let dropImage = dropRoot.appendingPathComponent("dragged.png")
        let dropVideo = dropRoot.appendingPathComponent("dragged.mov")
        let dropFile = dropRoot.appendingPathComponent("dragged.txt")
        try image.write(to: dropImage)
        try Data("movie bytes".utf8).write(to: dropVideo)
        try Data("document bytes".utf8).write(to: dropFile)
        for url in [dropImage, dropVideo, dropFile] {
            dropStore.addDroppedFilesToTransfer([url])
            try await finish { dropStore.transferBusy }
            precondition(dropStore.transferError == nil)
        }
        precondition(Set(dropStore.transferEntries.map(\.kind.rawValue)) == Set(["图片", "视频", "文件"]))
        precondition(dropStore.entries.isEmpty, "Direct drops must skip history by default")
        let countBeforeImage = dropStore.transferEntries.count
        dropStore.addDroppedImageToTransfer(image)
        try await finish { dropStore.transferBusy }
        precondition(dropStore.transferEntries.count == countBeforeImage,
                     "Image bytes and an image file URL must represent one transfer entry")
        dropStore.addDroppedTextToTransfer("Dragged text")
        try await finish { dropStore.transferBusy }
        precondition(dropStore.entries.isEmpty)
        dropStore.transferDropSavesHistory = true
        precondition(defaults.bool(forKey: "transferDropSavesHistory"))
        let secondFile = dropRoot.appendingPathComponent("second.txt")
        try Data("second".utf8).write(to: secondFile)
        dropStore.addDroppedFilesToTransfer([secondFile])
        try await finish { dropStore.transferBusy }
        precondition(dropStore.entries.count == 1 && dropStore.entries[0].kind == .file)
        dropStore.addDroppedTextToTransfer("Saved dragged text")
        try await finish { dropStore.transferBusy }
        precondition(dropStore.entries.count == 2 && dropStore.entries.contains { $0.plainText == "Saved dragged text" })
        let secondImage = dropRoot.appendingPathComponent("second.png")
        let differentImage = NSBitmapImageRep(data: image)!
        differentImage.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
        try differentImage.representation(using: .png, properties: [:])!.write(to: secondImage)
        dropStore.addDroppedFilesToTransfer([secondImage])
        try await finish { dropStore.transferBusy }
        precondition(dropStore.entries.count == 3 && dropStore.entries.contains { $0.kind == .image && $0.payloadName != nil })
        let countBeforeRepeats = dropStore.transferEntries.count
        let historyBeforeRepeats = dropStore.entries.count
        let fileAlias = dropRoot.appendingPathComponent("alias.txt")
        try fm.createSymbolicLink(at: fileAlias, withDestinationURL: dropFile)
        for url in [dropFile, fileAlias, secondImage] {
            dropStore.addDroppedFilesToTransfer([url, url])
            try await finish { dropStore.transferBusy }
        }
        dropStore.addDroppedTextToTransfer("Dragged text")
        try await finish { dropStore.transferBusy }
        precondition(dropStore.transferEntries.count == countBeforeRepeats && dropStore.entries.count == historyBeforeRepeats,
                     "Duplicate drops must change neither the shelf nor history")
        let historyBeforeFailure = dropStore.entries.count
        dropStore.addDroppedFilesToTransfer([dropRoot.appendingPathComponent("missing.mov")])
        try await finish { dropStore.transferBusy }
        precondition(dropStore.transferError != nil && dropStore.entries.count == historyBeforeFailure,
                     "Failed transfers must not enter history")
        let reopenedDropStore = ClipboardStore(storageDirectory: dropRoot, defaults: defaults,
                                               pasteboard: pasteboard, observesPasteboard: false)
        precondition(reopenedDropStore.transferDropSavesHistory)

        let draggedText = dropStore.transferEntries.first { $0.plainText == "Dragged text" }!
        let textProvider = dropStore.transferDragProvider(for: draggedText)!
        precondition(textProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        precondition(ClipboardStore.isTransferDrag([textProvider]))
        precondition(!ClipboardStore.isTransferDrag([NSItemProvider(object: "External text" as NSString)]))
        let draggedImage = dropStore.transferEntries.first { $0.kind == .image }!
        let imageProvider = dropStore.transferDragProvider(for: draggedImage)!
        precondition(imageProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        precondition(imageProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        let imageBytes = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            imageProvider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        precondition(imageBytes == image, "The image drag must provide image bytes")
        precondition(ClipboardStore.isTransferDrag([imageProvider]))
        let countBeforeRoundTrip = dropStore.transferEntries.count
        let historyBeforeRoundTrip = dropStore.entries.count
        for staged in dropStore.transferEntries where !staged.filePaths.isEmpty {
            let provider = dropStore.transferDragProvider(for: staged)!
            precondition(ClipboardStore.isTransferDrag([provider]))
            // Even if an intermediary removes the private marker, staged URLs
            // must not be imported as fresh files.
            dropStore.addDroppedFilesToTransfer(staged.filePaths.map { URL(fileURLWithPath: $0) })
            try await finish { dropStore.transferBusy }
        }
        precondition(dropStore.transferEntries.count == countBeforeRoundTrip && dropStore.entries.count == historyBeforeRoundTrip)
        for kind in [EntryKind.file, .video] {
            let item = dropStore.transferEntries.first { $0.kind == kind }!
            let provider = dropStore.transferDragProvider(for: item)!
            precondition(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
            let draggedURL = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: (object as? NSURL).map { $0 as URL })
                }
            }
            precondition(draggedURL == item.firstFileURL, "A file drag must vend a URL, not a path string")
            let bytes = try Data(contentsOf: draggedURL!)
            let originalBytes = try Data(contentsOf: item.firstFileURL!)
            precondition(bytes == originalBytes, "The dragged URL must point to the staged file bytes")
        }
        dropStore.addDroppedFilesToTransfer([dropFile, dropVideo])
        try await finish { dropStore.transferBusy }
        let group = dropStore.transferEntries.last!
        precondition(group.kind == .file && group.filePaths.count == 2)
        let groupProvider = dropStore.transferDragProvider(for: group)!
        precondition(groupProvider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let dragFolder = dropRoot.appendingPathComponent("Transfer")
            .appendingPathComponent(group.transferFolderName!).appendingPathComponent("拖出文件")
        let draggedFolder = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            groupProvider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
        precondition(draggedFolder == dragFolder)
        let exportedNames = try fm.contentsOfDirectory(atPath: dragFolder.path)
        precondition(Set(exportedNames) == Set([dropFile.lastPathComponent, dropVideo.lastPathComponent]))
        precondition(ClipboardStore.isTransferDrag([groupProvider]))
        let groupCount = dropStore.transferEntries.count
        dropStore.addDroppedFilesToTransfer([dragFolder])
        try await finish { dropStore.transferBusy }
        dropStore.addDroppedFilesToTransfer([dropVideo, dropFile, dropVideo])
        try await finish { dropStore.transferBusy }
        precondition(dropStore.transferEntries.count == groupCount,
                     "Neither exported groups nor reordered duplicate file sets may create another entry")
        // A child exports the staged file itself and retains the shelf identity.
        let childPath = group.filePaths[0]
        let childURL = URL(fileURLWithPath: childPath)
        let childBytes = try Data(contentsOf: childURL)
        let copiesBeforeChild = dropStore.transferEntries.first { $0.id == group.id }!.copyCount
        let childProvider = dropStore.transferFileDragProvider(childPath, in: group)!
        let childExport = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            childProvider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL).map { $0 as URL })
            }
        }
        precondition(childExport == childURL && ClipboardStore.isTransferDrag([childProvider]))
        precondition(dropStore.transferEntries.first { $0.id == group.id }!.copyCount == copiesBeforeChild,
                     "Dragging one child must not count as copying the group")
        precondition(dropStore.copyTransferFile(childPath, in: group))
        let copiedChildren = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        precondition(copiedChildren == [childURL], "Copy only the selected child as a file URL")
        precondition(dropStore.transferEntries.first { $0.id == group.id }!.copyCount == copiesBeforeChild + 1)
        precondition(!dropStore.acceptTransferFileDrop([childProvider]), "Children dragged back must not import duplicates")
        let unchangedClipboard = pasteboard.changeCount
        precondition(!dropStore.copyTransferFile(dropFile.path, in: group), "Reject source paths outside the saved group")
        precondition(dropStore.transferFileDragProvider(dropFile.path, in: group) == nil)
        precondition(pasteboard.changeCount == unchangedClipboard)
        try fm.removeItem(at: childURL)
        precondition(!dropStore.copyTransferFile(childPath, in: group))
        precondition(dropStore.transferFileDragProvider(childPath, in: group) == nil)
        precondition(pasteboard.changeCount == unchangedClipboard)
        precondition(dropStore.contentAvailability(for: group).isPartial, "A missing child must not mark the whole group missing")
        try childBytes.write(to: childURL)
        precondition(dropStore.copyTransferFile(childPath, in: group))
        dropStore.availabilityError = nil
        dropStore.dragError = nil
        print("PASS: group-child real file URLs, independent copy/drag, parent count, self-drop rejection and missing/foreign path protection")

        // All list surfaces use the same provider, including saved images that
        // no longer have an original, and separate groups in ordinary history.
        let dragRoot = root.appendingPathComponent("HistoryDragTests")
        try fm.createDirectory(at: dragRoot, withIntermediateDirectories: true)
        let cachedImage = dragRoot.appendingPathComponent("captured.png")
        try image.write(to: cachedImage)
        let cachedRTF = dragRoot.appendingPathComponent("captured.rtf")
        try rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!.write(to: cachedRTF)
        let documentA = dragRoot.appendingPathComponent("A.txt")
        let documentB = dragRoot.appendingPathComponent("B.txt")
        let movie = dragRoot.appendingPathComponent("clip.mov")
        try Data("A bytes".utf8).write(to: documentA)
        try Data("B bytes".utf8).write(to: documentB)
        try Data("movie bytes".utf8).write(to: movie)
        let listItems = [entry(.text, text: rich.string, payload: "captured.rtf"),
                         entry(.image, paths: [dragRoot.appendingPathComponent("removed.png").path], payload: "captured.png"),
                         entry(.file, paths: [documentA.path]),
                         entry(.video, paths: [movie.path]),
                         entry(.file, paths: [documentA.path, documentB.path]),
                         entry(.file, paths: [documentB.path, movie.path])]
        try JSONEncoder().encode(listItems).write(to: dragRoot.appendingPathComponent("history.json"))
        let dragStore = ClipboardStore(storageDirectory: dragRoot, defaults: defaults,
                                       pasteboard: pasteboard, observesPasteboard: false)
        let metadataEncoder = JSONEncoder()
        metadataEncoder.outputFormatting = .sortedKeys
        let metadataBeforeDrag = try metadataEncoder.encode(dragStore.entries)
        let richProvider = dragStore.entryDragProvider(for: listItems[0])!
        precondition(!ClipboardStore.isTransferDrag([richProvider]), "History can still be dragged into the shelf")
        let plainText = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            richProvider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString).map { $0 as String })
            }
        }
        precondition(plainText == rich.string)
        let richBytes = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            richProvider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        precondition(richBytes == (try? Data(contentsOf: cachedRTF)))
        var exportedURLs: [URL] = []
        for item in listItems.dropFirst() {
            let provider = dragStore.entryDragProvider(for: item)!
            precondition(!ClipboardStore.isTransferDrag([provider]))
            let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    continuation.resume(returning: (object as? NSURL).map { $0 as URL })
                }
            }
            precondition(url?.isFileURL == true && fm.fileExists(atPath: url!.path))
            exportedURLs.append(url!)
        }
        precondition(exportedURLs[0] == cachedImage, "Image drag must use the saved payload when original is missing")
        precondition(exportedURLs[1] == documentA && exportedURLs[2] == movie)
        precondition(exportedURLs[3] != exportedURLs[4], "History file groups need independent export folders")
        let firstNames = try fm.contentsOfDirectory(atPath: exportedURLs[3].path)
        let secondNames = try fm.contentsOfDirectory(atPath: exportedURLs[4].path)
        precondition(Set(firstNames) == Set(["A.txt", "B.txt"]))
        precondition(Set(secondNames) == Set(["B.txt", "clip.mov"]))
        for url in exportedURLs.suffix(2) { try fm.removeItem(at: url.deletingLastPathComponent()) }
        let metadataAfterDrag = try metadataEncoder.encode(dragStore.entries)
        precondition(metadataAfterDrag == metadataBeforeDrag, "Dragging must not copy, reorder or increment counts")
        precondition(dragStore.transferEntries.isEmpty)
        dragStore.addToNotebook(listItems[1])
        try await finish { dragStore.notebookBusy }
        let savedImage = dragStore.notebookEntries[0]
        let savedProvider = dragStore.entryDragProvider(for: savedImage)!
        precondition(savedProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        precondition(!ClipboardStore.isTransferDrag([savedProvider]))
        var stale = listItems[0]
        stale.id = UUID()
        precondition(dragStore.entryDragProvider(for: stale) == nil)
        try fm.removeItem(at: documentA)
        precondition(dragStore.entryDragProvider(for: listItems[2]) == nil && dragStore.dragError != nil)
        // Finder multi-selection and mixed URL/file-representation sources.
        let batchRoot = root.appendingPathComponent("BatchDropTests")
        try fm.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        let batch = ClipboardStore(storageDirectory: batchRoot, defaults: defaults,
                                    pasteboard: pasteboard, observesPasteboard: false)
        batch.transferDropSavesHistory = false
        let urlProvider = NSItemProvider(object: dropFile as NSURL)
        let dataProvider = NSItemProvider()
        dataProvider.suggestedName = "second-document.txt"
        dataProvider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                                fileOptions: [], visibility: .all) { completion in
            completion(secondFile, false, nil)
            return nil
        }
        // Binary files can be supplied by a URL alongside a concrete image type.
        let pictureProvider = NSItemProvider()
        pictureProvider.suggestedName = "picture.png"
        pictureProvider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier,
                                                   fileOptions: [], visibility: .all) { completion in
            completion(dropImage, false, nil)
            return nil
        }
        precondition(batch.acceptTransferFileDrop([urlProvider, NSItemProvider(object: dropVideo as NSURL), pictureProvider, dataProvider]))
        precondition(!batch.acceptTransferFileDrop([urlProvider]), "Concurrent imports must not overwrite a loading group")
        try await finish { batch.transferDropLoading || batch.transferBusy }
        precondition(batch.transferError == nil && batch.transferEntries.count == 1)
        let batchEntry = batch.transferEntries[0]
        precondition(batchEntry.filePaths.count == 4)
        let importedPicture = try Data(contentsOf: URL(fileURLWithPath: batchEntry.filePaths[2]))
        precondition(importedPicture == image)
        precondition(!batch.acceptTransferFileDrop([batch.transferDragProvider(for: batchEntry)!]))
        let badProvider = NSItemProvider()
        badProvider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier,
                                               fileOptions: [], visibility: .all) { completion in
            completion(nil, false, CocoaError(.fileReadUnknown))
            return nil
        }
        precondition(batch.acceptTransferFileDrop([urlProvider, badProvider]))
        try await finish { batch.transferDropLoading || batch.transferBusy }
        precondition(batch.transferEntries.count == 1 && batch.transferError != nil,
                     "Failed batches must not import only part of the selected files")
        batch.transferDropSavesHistory = true
        let historyFile = NSItemProvider()
        historyFile.suggestedName = "history.txt"
        historyFile.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                               fileOptions: [], visibility: .all) { completion in
            completion(secondFile, false, nil)
            return nil
        }
        precondition(batch.acceptTransferFileDrop([historyFile]))
        try await finish { batch.transferDropLoading || batch.transferBusy }
        precondition(batch.entries.count == 1)
        let historyURL = batch.entries[0].firstFileURL!
        precondition(fm.fileExists(atPath: historyURL.path), "Materialized files saved in history must survive staging cleanup")
        batch.clearTransfer()
        try await finish { batch.transferBusy }
        precondition(fm.fileExists(atPath: historyURL.path))
        batch.clearUnpinned()
        precondition(!fm.fileExists(atPath: historyURL.path), "App-owned import files are cleaned with their history record")
        // Both UI destinations use this provider pipeline for folder decisions.
        let folderRoot = root.appendingPathComponent("FolderChoices")
        let folderSource = folderRoot.appendingPathComponent("项目资料")
        let nested = folderSource.appendingPathComponent("子目录")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested content".utf8).write(to: nested.appendingPathComponent("nested.txt"))
        try image.write(to: folderSource.appendingPathComponent("cover.png"))
        try Data("read me".utf8).write(to: folderSource.appendingPathComponent("readme.txt"))
        let folderStorePath = folderRoot.appendingPathComponent("Store")
        let folderStore = ClipboardStore(storageDirectory: folderStorePath, defaults: defaults,
                                        pasteboard: pasteboard, observesPasteboard: false)
        folderStore.transferDropSavesHistory = false
        precondition(folderStore.transferFolderDropBehavior == .ask)
        var folderPrompts = 0
        folderStore.folderDropConfirmation = { folders in
            folderPrompts += 1
            precondition(folders == [folderSource])
            return TransferFolderDropDecision(behavior: .groupContents, remember: true)
        }
        func dropFolder(_ urls: [URL]) async throws {
            precondition(folderStore.acceptTransferFileDrop(urls.map { NSItemProvider(object: $0 as NSURL) }))
            try await finish { folderStore.transferDropLoading || folderStore.transferBusy }
            precondition(folderStore.transferError == nil)
        }
        try await dropFolder([folderSource, folderSource])
        let folderGroup = folderStore.transferEntries[0]
        precondition(folderPrompts == 1 && folderStore.transferFolderDropBehavior == .groupContents)
        precondition(folderGroup.isFileGroup && folderGroup.fileGroupName == "项目资料" && folderGroup.filePaths.count == 3)
        let archivedNested = folderGroup.filePaths.first { URL(fileURLWithPath: $0).lastPathComponent == "子目录" }!
        let nestedBytes = try Data(contentsOf: URL(fileURLWithPath: archivedNested).appendingPathComponent("nested.txt"))
        precondition(nestedBytes == Data("nested content".utf8))
        try await dropFolder([folderSource])
        precondition(folderPrompts == 1 && folderStore.transferEntries.count == 1, "Remembered grouping must deduplicate without prompting")
        let singleFolder = folderRoot.appendingPathComponent("单文件目录")
        try fm.createDirectory(at: singleFolder, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: singleFolder.appendingPathComponent("one.txt"))
        try await dropFolder([singleFolder])
        precondition(folderStore.transferEntries.last!.isFileGroup && folderStore.transferEntries.last!.filePaths.count == 1,
                     "A one-child folder still has expandable group identity")
        let reopenedFolders = ClipboardStore(storageDirectory: folderStorePath, defaults: defaults,
                                             pasteboard: pasteboard, observesPasteboard: false)
        precondition(reopenedFolders.transferFolderDropBehavior == .groupContents)
        precondition(reopenedFolders.transferEntries.last!.fileGroupName == "单文件目录")
        folderStore.transferFolderDropBehavior = .keepFolder
        try await dropFolder([singleFolder])
        let intact = folderStore.transferEntries.last!
        precondition(!intact.isFileGroup && intact.filePaths.count == 1)
        precondition(fm.fileExists(atPath: URL(fileURLWithPath: intact.filePaths[0]).appendingPathComponent("one.txt").path))
        folderStore.transferFolderDropBehavior = .ask
        folderStore.folderDropConfirmation = { _ in folderPrompts += 1; return nil }
        let countBeforeCancel = folderStore.transferEntries.count
        try await dropFolder([folderSource])
        precondition(folderStore.transferDropCancelled && folderStore.transferEntries.count == countBeforeCancel)
        precondition(folderStore.transferFolderDropBehavior == .ask && folderStore.entries.isEmpty,
                     "Cancel must not save a preference, history, or shelf data")
        folderStore.folderDropConfirmation = { _ in
            TransferFolderDropDecision(behavior: .keepFolder, remember: false)
        }
        try await dropFolder([folderSource])
        precondition(!folderStore.transferDropCancelled && folderStore.transferFolderDropBehavior == .ask)
        let emptyFolder = folderRoot.appendingPathComponent("空文件夹")
        try fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        folderStore.transferFolderDropBehavior = .groupContents
        try await dropFolder([emptyFolder])
        precondition(folderStore.transferEntries.last!.isFileGroup && folderStore.transferEntries.last!.filePaths.count == 1)
        precondition(fm.fileExists(atPath: folderStore.transferEntries.last!.filePaths[0]))
        try fm.removeItem(at: folderSource)
        precondition(fm.fileExists(atPath: archivedNested), "Grouped folder children must survive source deletion")
        print("PASS: folder group/whole/cancel choices, remember preference, restart, one-child and empty groups, nested contents, dedup and source isolation")

        print("PASS: multi-provider mixed file drops, temporary file lifetime, loading guard and atomic failure")
        print("PASS: history/notebook text, RTF, captured image, file/video URLs, independent groups, missing originals and unchanged metadata")
        print("PASS: transfer content, direct text/image/file/video drops, drag providers and previews, optional history, deduplication, original removal, notebook isolation, close deadline, reopen cancellation, interval settings, restart and failure protection")
    }

    @MainActor static func finish(_ isBusy: () -> Bool) async throws {
        for _ in 0..<500 {
            if !isBusy() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Transfer operation timed out")
    }
}
