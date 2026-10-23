import AppKit
import AVFoundation
import Combine
import CryptoKit
import MediaToolSwift
import SwiftUI
import UniformTypeIdentifiers

enum EntryKind: String, Codable, CaseIterable {
    case text = "文字", image = "图片", file = "文件", video = "视频"

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .file: "doc"
        case .video: "play.rectangle"
        }
    }
}

enum ClipboardSortOrder: String, CaseIterable, Identifiable {
    case recent = "时间排序", frequency = "次数排序"
    var id: String { rawValue }

    init(storedValue: String) {
        switch storedValue {
        case "最近复制": self = .recent
        case "复制次数": self = .frequency
        default: self = Self(rawValue: storedValue) ?? .recent
        }
    }
}

struct ClipboardEntry: Codable, Identifiable {
    var id: UUID
    var kind: EntryKind
    var fingerprint: String
    var plainText: String?
    var filePaths: [String]
    var payloadName: String?
    var thumbnailName: String?
    var sourceAppName: String
    var sourceBundleID: String?
    var createdAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    var isPinned: Bool
    var notebookFolderName: String? = nil
    var previewAspectRatio: CGFloat? = nil
    var transferFolderName: String? = nil

    var isNotebookEntry: Bool { notebookFolderName != nil }
    var isTransferEntry: Bool { transferFolderName != nil }

    var title: String {
        switch kind {
        case .text: plainText?.replacingOccurrences(of: "\n", with: " ") ?? "文字"
        case .image: filePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "图片.png"
        case .file, .video: filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }
    }

    var searchText: String { "\(title) \(sourceAppName)" }
    var firstFileURL: URL? { filePaths.first.map { URL(fileURLWithPath: $0) } }
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = [] {
        didSet { sortedHistoryCache = nil }
    }
    @Published private(set) var notebookEntries: [ClipboardEntry] = [] {
        didSet { sortedNotebookCache = nil }
    }
    @Published private(set) var notebookDirectory: URL
    @Published private(set) var notebookBusy = false
    @Published var notebookError: String?
    @Published private(set) var transferEntries: [ClipboardEntry] = []
    @Published private(set) var transferBusy = false
    @Published private(set) var transferWindowVisible = false
    @Published private(set) var transferClosedAt: Date?
    @Published var transferError: String?
    @Published var dragError: String?
    @Published var transferDropSavesHistory = false {
        didSet { defaults.set(transferDropSavesHistory, forKey: "transferDropSavesHistory") }
    }
    @Published var transferClearMinutes = 10 {
        didSet {
            let bounded = min(1440, max(1, transferClearMinutes))
            if transferClearMinutes != bounded {
                transferClearMinutes = bounded
                return
            }
            defaults.set(transferClearMinutes, forKey: "transferClearMinutes")
            scheduleTransferCleanup()
        }
    }
    @Published var sortOrder: ClipboardSortOrder = .recent {
        didSet {
            sortedHistoryCache = nil
            sortedNotebookCache = nil
            defaults.set(sortOrder.rawValue, forKey: "sortOrder")
        }
    }
    @Published var maxEntries: Int = 500 {
        didSet { defaults.set(maxEntries, forKey: "maxEntries"); trimAndSave() }
    }

    private let pasteboard: NSPasteboard
    private let defaults: UserDefaults
    private let folder: URL
    private var lastChangeCount: Int
    private var timer: Timer?
    private var pendingVideoThumbnails: Set<UUID> = []
    private var failedVideoThumbnails: Set<UUID> = []
    private var archivingHistoryIDs: Set<UUID> = []
    private var notebookLoadFailed = false
    private var sortedHistoryCache: [ClipboardEntry]?
    private var sortedNotebookCache: [ClipboardEntry]?
    private var previewRevisions: [UUID: Int] = [:]
    private var transferCleanupTask: Task<Void, Never>?
    private var transferSourceIDs: Set<UUID> = []
    private var transferLoadFailed = false
    private var terminationObservation: AnyCancellable?

    private var transferDirectory: URL { folder.appendingPathComponent("Transfer", isDirectory: true) }

    private struct TransferState: Codable {
        var entries: [ClipboardEntry]
        var closedAt: Date?
    }

    var sortedEntries: [ClipboardEntry] {
        if let sortedHistoryCache { return sortedHistoryCache }
        let result = sorted(entries)
        sortedHistoryCache = result
        return result
    }

    var sortedNotebookEntries: [ClipboardEntry] {
        if let sortedNotebookCache { return sortedNotebookCache }
        let result = sorted(notebookEntries)
        sortedNotebookCache = result
        return result
    }

    private func sorted(_ items: [ClipboardEntry]) -> [ClipboardEntry] {
        items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if sortOrder == .frequency && lhs.copyCount != rhs.copyCount { return lhs.copyCount > rhs.copyCount }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    init(storageDirectory: URL? = nil, defaults: UserDefaults = .standard,
         pasteboard: NSPasteboard = .general, observesPasteboard: Bool = true) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        folder = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperClipboard", isDirectory: true)
        notebookDirectory = defaults.string(forKey: "notebookDirectory")
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? folder.appendingPathComponent("Notebook", isDirectory: true)
        lastChangeCount = pasteboard.changeCount
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("history.json")),
           let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) {
            entries = decoded
        }
        var migratedImageFiles = false
        for index in entries.indices where entries[index].kind == .file && entries[index].filePaths.count == 1 {
            let path = entries[index].filePaths[0]
            if UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .image) == true {
                entries[index].kind = .image
                entries[index].fingerprint = hash(Data((EntryKind.image.rawValue + path).utf8))
                migratedImageFiles = true
            }
        }
        if migratedImageFiles { save() }
        do {
            try FileManager.default.createDirectory(at: notebookDirectory, withIntermediateDirectories: true)
            let indexURL = notebookDirectory.appendingPathComponent("notebook.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                notebookEntries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: indexURL))
            }
        } catch {
            notebookLoadFailed = true
            notebookError = "无法读取记事本：\(error.localizedDescription)"
        }
        if let raw = defaults.string(forKey: "sortOrder") {
            sortOrder = ClipboardSortOrder(storedValue: raw)
        }
        if let count = defaults.object(forKey: "maxEntries") as? Int { maxEntries = count }
        if let minutes = defaults.object(forKey: "transferClearMinutes") as? Int {
            transferClearMinutes = min(1440, max(1, minutes))
        }
        transferDropSavesHistory = defaults.bool(forKey: "transferDropSavesHistory")
        do {
            let index = transferDirectory.appendingPathComponent("transfer.json")
            if FileManager.default.fileExists(atPath: index.path) {
                let state = try JSONDecoder().decode(TransferState.self, from: Data(contentsOf: index))
                transferEntries = state.entries
                transferClosedAt = state.closedAt ?? Date()
                try writeTransferState()
            }
        } catch {
            transferLoadFailed = true
            transferError = "无法读取中转站：\(error.localizedDescription)"
        }
        scheduleTransferCleanup()
        terminationObservation = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.transferWindowDidClose() }
        for item in entries where item.kind == .video { ensureVideoThumbnail(for: item) }
        if observesPasteboard {
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPasteboard() }
            }
        }
    }

    private func checkPasteboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let source = NSWorkspace.shared.frontmostApplication
        let sourceName = source?.localizedName ?? "未知应用"
        let sourceID = source?.bundleIdentifier

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            let isImage = paths.count == 1 && (UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .image) == true)
            let isVideo = paths.count == 1 && (UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .movie) == true)
            let kind: EntryKind = isImage ? .image : (isVideo ? .video : .file)
            let fingerprint = hash(Data((kind.rawValue + paths.joined(separator: "\u{0}")).utf8))
            let fileImageData = isImage ? imageData(from: urls[0]) : nil
            let imagePayload = fileImageData ?? (isImage ? pasteboardImageData() : nil)
            record(kind: kind, fingerprint: fingerprint, text: nil, paths: paths,
                   payload: imagePayload, payloadExtension: fileImageData == nil ? "png" : urls[0].pathExtension,
                   thumbnail: nil, sourceName: sourceName, sourceID: sourceID)
            return
        }

        if let png = pasteboardImageData() {
            record(kind: .image, fingerprint: hash(png), text: nil, paths: [], payload: png, thumbnail: nil, sourceName: sourceName, sourceID: sourceID)
            return
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let rtf = richTextData()
            let fingerprint = hash(Data(string.utf8))
            record(kind: .text, fingerprint: fingerprint, text: string, paths: [], payload: rtf, thumbnail: nil, sourceName: sourceName, sourceID: sourceID)
        }
    }

    private func imageData(from url: URL) -> Data? {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
        return data
    }

    private func pasteboardImageData() -> Data? {
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func richTextData() -> Data? {
        if let rtf = pasteboard.data(forType: .rtf) { return rtf }
        var documentAttributes: NSDictionary?
        if let rtfd = pasteboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: rtfd, documentAttributes: &documentAttributes) {
            return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: rtfDocumentAttributes(documentAttributes))
        }
        if let html = pasteboard.data(forType: .html),
           let attributed = NSAttributedString(html: html, documentAttributes: &documentAttributes) {
            return attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: rtfDocumentAttributes(documentAttributes))
        }
        return nil
    }

    private func rtfDocumentAttributes(_ attributes: NSDictionary?) -> [NSAttributedString.DocumentAttributeKey: Any] {
        var result: [NSAttributedString.DocumentAttributeKey: Any] = [:]
        for (key, value) in attributes ?? [:] {
            if let key = key as? String {
                result[NSAttributedString.DocumentAttributeKey(rawValue: key)] = value
            }
        }
        result[.documentType] = NSAttributedString.DocumentType.rtf
        return result
    }

    private func record(kind: EntryKind, fingerprint: String, text: String?, paths: [String], payload: Data?, payloadExtension: String? = nil, thumbnail: Data?, sourceName: String, sourceID: String?) {
        let now = Date()
        let fileExtension = kind == .text ? "rtf" : (payloadExtension.flatMap { $0.isEmpty ? nil : $0 } ?? "png")
        if let index = entries.firstIndex(where: { $0.kind == kind && $0.fingerprint == fingerprint }) {
            previewRevisions[entries[index].id, default: 0] += 1
            entries[index].copyCount += 1
            entries[index].lastCopiedAt = now
            entries[index].sourceAppName = sourceName
            entries[index].sourceBundleID = sourceID
            if let payload {
                if kind == .image { entries[index].previewAspectRatio = ClipboardPreviewImage.aspectRatio(data: payload) }
                let name = entries[index].payloadName ?? "\(entries[index].id.uuidString).\(fileExtension)"
                try? payload.write(to: folder.appendingPathComponent(name), options: .atomic)
                entries[index].payloadName = name
            }
            if let thumbnail {
                let name = entries[index].thumbnailName ?? "\(entries[index].id.uuidString)-thumbnail.png"
                try? thumbnail.write(to: folder.appendingPathComponent(name), options: .atomic)
                entries[index].thumbnailName = name
            }
            save()
            if kind == .video { ensureVideoThumbnail(for: entries[index]) }
            return
        }

        let id = UUID()
        let payloadName = payload.map { _ in "\(id.uuidString).\(fileExtension)" }
        let thumbnailName = thumbnail.map { _ in "\(id.uuidString)-thumbnail.png" }
        if let payload, let payloadName { try? payload.write(to: folder.appendingPathComponent(payloadName), options: .atomic) }
        if let thumbnail, let thumbnailName { try? thumbnail.write(to: folder.appendingPathComponent(thumbnailName), options: .atomic) }
        entries.append(ClipboardEntry(id: id, kind: kind, fingerprint: fingerprint, plainText: text,
                                      filePaths: paths, payloadName: payloadName, thumbnailName: thumbnailName,
                                      sourceAppName: sourceName, sourceBundleID: sourceID, createdAt: now,
                                      lastCopiedAt: now, copyCount: 1, isPinned: false))
        if kind == .image, let payload, let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].previewAspectRatio = ClipboardPreviewImage.aspectRatio(data: payload)
        }
        trimAndSave()
        if kind == .video, let item = entries.first(where: { $0.id == id }) {
            ensureVideoThumbnail(for: item)
        }
    }

    @discardableResult
    func copy(_ item: ClipboardEntry) -> Bool {
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            if let name = item.payloadName, let data = try? Data(contentsOf: storageFolder(for: item).appendingPathComponent(name)) {
                pasteboard.setData(data, forType: .rtf)
            }
            guard pasteboard.setString(item.plainText ?? "", forType: .string) else { return false }
        case .image:
            if let name = item.payloadName,
               let data = try? Data(contentsOf: storageFolder(for: item).appendingPathComponent(name)),
               let image = NSImage(data: data) {
                pasteboard.clearContents()
                guard pasteboard.writeObjects([image]) else { return false }
                break
            }
            if !item.filePaths.isEmpty {
                let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
                guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return false }
                pasteboard.clearContents()
                guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
                break
            }
            return false
        case .file, .video:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return false }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        }
        lastChangeCount = pasteboard.changeCount
        if item.isTransferEntry, let index = transferEntries.firstIndex(where: { $0.id == item.id }) {
            transferEntries[index].copyCount += 1
            transferEntries[index].lastCopiedAt = Date()
            persistTransfer()
        } else if item.isNotebookEntry, let index = notebookEntries.firstIndex(where: { $0.id == item.id }) {
            notebookEntries[index].copyCount += 1
            notebookEntries[index].lastCopiedAt = Date()
            persistNotebook()
        } else if let index = entries.firstIndex(where: { $0.id == item.id }) {
            entries[index].copyCount += 1
            entries[index].lastCopiedAt = Date()
            save()
        }
        return true
    }

    func togglePin(_ item: ClipboardEntry) {
        if item.isNotebookEntry, let index = notebookEntries.firstIndex(where: { $0.id == item.id }) {
            notebookEntries[index].isPinned.toggle()
            persistNotebook()
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
        entries[index].isPinned.toggle()
        save()
    }

    func delete(_ item: ClipboardEntry) {
        if item.isTransferEntry {
            removeFromTransfer(item)
            return
        }
        if item.isNotebookEntry {
            guard !notebookBusy, !transferBusy else { return }
            let remaining = notebookEntries.filter { $0.id != item.id }
            do {
                try writeNotebook(remaining, to: notebookDirectory)
                notebookEntries = remaining
                if let name = item.notebookFolderName {
                    try? FileManager.default.removeItem(at: notebookDirectory.appendingPathComponent(name))
                }
            } catch { notebookError = "无法移除记事本条目：\(error.localizedDescription)" }
            return
        }
        entries.removeAll { $0.id == item.id }
        removeFiles(for: item)
        save()
    }

    func clearUnpinned() {
        for item in entries where !item.isPinned { removeFiles(for: item) }
        entries.removeAll { !$0.isPinned }
        save()
    }

    func isInNotebook(_ item: ClipboardEntry) -> Bool {
        notebookEntries.contains { $0.fingerprint == item.fingerprint }
    }

    private func storageFolder(for item: ClipboardEntry) -> URL {
        if let name = item.transferFolderName { return transferDirectory.appendingPathComponent(name, isDirectory: true) }
        guard let name = item.notebookFolderName else { return folder }
        return notebookDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func addToNotebook(_ item: ClipboardEntry) {
        guard !notebookBusy, !transferBusy, !isInNotebook(item) else { return }
        guard !notebookLoadFailed else {
            notebookError = "请先恢复记事本目录中的 notebook.json，避免覆盖已有存档。"
            return
        }
        notebookBusy = true
        archivingHistoryIDs.insert(item.id)
        let sourceFolder = storageFolder(for: item)
        let destination = notebookDirectory
        let archiveID = UUID()
        let thumbnail = item.thumbnailName ?? (item.kind == .video ? "\(item.id.uuidString)-thumbnail.png" : nil)
        Task {
            defer {
                notebookBusy = false
                archivingHistoryIDs.remove(item.id)
                if !entries.contains(where: { $0.id == item.id }) { removeFiles(for: item) }
            }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try NotebookStorage.archive(id: archiveID, sourceFolder: sourceFolder, destination: destination,
                                                filePaths: item.filePaths, payloadName: item.payloadName,
                                                thumbnailName: thumbnail, requiresFiles: item.kind == .file || item.kind == .video,
                                                requiresImage: item.kind == .image)
                }.value
                var archived = item
                archived.id = archiveID
                archived.isPinned = false
                archived.notebookFolderName = snapshot.directoryName
                archived.transferFolderName = nil
                archived.filePaths = snapshot.filePaths
                archived.payloadName = snapshot.payloadName
                archived.thumbnailName = snapshot.thumbnailName
                let updated = [archived] + notebookEntries
                do {
                    try writeNotebook(updated, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination.appendingPathComponent(snapshot.directoryName))
                    throw error
                }
                notebookEntries = updated
                if archived.kind == .video { ensureVideoThumbnail(for: archived) }
            } catch { notebookError = "加入记事本失败：\(error.localizedDescription)" }
        }
    }

    func chooseNotebookDirectory() {
        guard !notebookBusy, !transferBusy else { return }
        guard !notebookLoadFailed else {
            notebookError = "请先恢复记事本目录中的 notebook.json，再迁移保存位置。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择并迁移"
        panel.message = "将在所选位置创建 SuperClipboard Notebook 文件夹，并迁移已有记事本。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        changeNotebookDirectory(to: parent.appendingPathComponent("SuperClipboard Notebook", isDirectory: true))
    }

    func changeNotebookDirectory(to destination: URL) {
        guard !notebookBusy, !transferBusy, !notebookLoadFailed else { return }
        guard destination.resolvingSymlinksInPath().standardizedFileURL.path != notebookDirectory.resolvingSymlinksInPath().standardizedFileURL.path else { return }
        let source = notebookDirectory
        notebookBusy = true
        Task {
            defer { notebookBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try NotebookStorage.relocate(from: source, to: destination)
                }.value
                var relocated = notebookEntries
                for index in relocated.indices {
                    relocated[index].filePaths = relocated[index].filePaths.map { path in
                        let prefix = source.path + "/"
                        return path.hasPrefix(prefix) ? destination.appendingPathComponent(String(path.dropFirst(prefix.count))).path : path
                    }
                }
                do {
                    try writeNotebook(relocated, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
                defaults.set(destination.path, forKey: "notebookDirectory")
                notebookDirectory = destination
                notebookEntries = relocated
                try? FileManager.default.removeItem(at: source)
            } catch { notebookError = "迁移记事本失败：\(error.localizedDescription)" }
        }
    }

    private func writeNotebook(_ items: [ClipboardEntry], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(items).write(to: directory.appendingPathComponent("notebook.json"), options: .atomic)
    }

    private func persistNotebook() {
        do { try writeNotebook(notebookEntries, to: notebookDirectory) }
        catch { notebookError = "保存记事本失败：\(error.localizedDescription)" }
    }

    func isInTransfer(_ item: ClipboardEntry) -> Bool {
        transferEntries.contains {
            $0.fingerprint == item.fingerprint ||
            (item.kind == .text && $0.kind == .text && $0.plainText == item.plainText)
        }
    }

    static let transferDragTypeIdentifier = "com.superclipboard.transfer-entry"

    static func isTransferDrag(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(transferDragTypeIdentifier) }
    }

    private func markTransferDrag(_ provider: NSItemProvider, item: ClipboardEntry) -> NSItemProvider {
        let identity = Data(item.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.transferDragTypeIdentifier,
                                            visibility: .ownProcess) { completion in
            completion(identity, nil)
            return nil
        }
        return provider
    }

    func transferDragProvider(for item: ClipboardEntry) -> NSItemProvider? {
        guard item.isTransferEntry, transferEntries.contains(where: { $0.id == item.id }) else { return nil }
        return entryDragProvider(for: item)
    }

    func entryDragProvider(for item: ClipboardEntry) -> NSItemProvider? {
        let collection = item.isTransferEntry ? transferEntries : (item.isNotebookEntry ? notebookEntries : entries)
        guard collection.contains(where: { $0.id == item.id }) else { return nil }
        func providerForOrigin(_ provider: NSItemProvider) -> NSItemProvider {
            item.isTransferEntry ? markTransferDrag(provider, item: item) : provider
        }
        switch item.kind {
        case .text:
            guard let text = item.plainText, !text.isEmpty else { return nil }
            let provider = NSItemProvider(object: text as NSString)
            if let name = item.payloadName {
                let url = storageFolder(for: item).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    provider.registerDataRepresentation(forTypeIdentifier: UTType.rtf.identifier, visibility: .all) { completion in
                        do { completion(try Data(contentsOf: url), nil) }
                        catch { completion(nil, error) }
                        return nil
                    }
                }
            }
            return providerForOrigin(provider)
        case .image, .file, .video:
            let url: URL
            if item.kind == .image, let name = item.payloadName,
               FileManager.default.fileExists(atPath: storageFolder(for: item).appendingPathComponent(name).path) {
                // Captured image bytes remain valid after the original is removed.
                url = storageFolder(for: item).appendingPathComponent(name)
            } else if item.filePaths.count == 1, let first = item.firstFileURL {
                url = first
            } else if item.filePaths.count > 1 {
                do { url = try transferDragFolder(for: item) }
                catch {
                    dragError = "无法准备拖出的文件：\(error.localizedDescription)"
                    return nil
                }
            } else {
                dragError = "这条记录没有可拖出的文件。"
                return nil
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                dragError = "原文件已被移动或删除，无法拖出。"
                return nil
            }
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = url.lastPathComponent
            if item.kind == .image, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
                    do { completion(try Data(contentsOf: url), nil) }
                    catch { completion(nil, error) }
                    return nil
                }
            }
            return providerForOrigin(provider)
        }
    }

    private func transferDragFolder(for item: ClipboardEntry) throws -> URL {
        let fm = FileManager.default
        let directory = item.isTransferEntry || item.isNotebookEntry
            ? storageFolder(for: item)
            : fm.temporaryDirectory.appendingPathComponent("SuperClipboard-DragExports", isDirectory: true)
                .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let output = directory.appendingPathComponent("拖出文件", isDirectory: true)
        if fm.fileExists(atPath: output.path) { return output }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            for (index, path) in item.filePaths.enumerated() {
                let source = URL(fileURLWithPath: path)
                let name = source.lastPathComponent
                let target = output.appendingPathComponent(
                    fm.fileExists(atPath: output.appendingPathComponent(name).path) ? "\(index + 1)-\(name)" : name)
                do { try fm.linkItem(at: source, to: target) }
                catch { try fm.copyItem(at: source, to: target) }
            }
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
        return output
    }

    func addDroppedFilesToTransfer(_ urls: [URL]) {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        var seen = Set<String>()
        let uniqueURLs = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
        // A destination may strip our private drag marker. Staged payloads and
        // exported file groups still belong to this shelf and must not re-enter.
        let shelfPath = transferDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard !uniqueURLs.contains(where: { $0.path == shelfPath || $0.path.hasPrefix(shelfPath + "/") }) else { return }
        let kind: EntryKind
        if uniqueURLs.count == 1, let type = UTType(filenameExtension: uniqueURLs[0].pathExtension) {
            kind = type.conforms(to: .image) ? .image : (type.conforms(to: .movie) ? .video : .file)
        } else {
            kind = .file
        }
        let paths = uniqueURLs.map(\.path)
        let fingerprint: String
        if kind == .image, let data = imageData(from: uniqueURLs[0]) {
            fingerprint = hash(data)
            guard !containsTransferImage(fingerprint: fingerprint) else { return }
        } else {
            // File order and duplicate URLs within the drop do not change its identity.
            fingerprint = hash(Data((kind.rawValue + paths.sorted().joined(separator: "\u{0}")).utf8))
        }
        let item = ClipboardEntry(id: UUID(), kind: kind, fingerprint: fingerprint,
            plainText: nil, filePaths: paths, payloadName: nil, thumbnailName: nil,
            sourceAppName: "拖放导入", sourceBundleID: nil, createdAt: Date(),
            lastCopiedAt: Date(), copyCount: 1, isPinned: false)
        addToTransfer(item, recordDropInHistory: transferDropSavesHistory)
    }

    private func containsTransferImage(fingerprint: String) -> Bool {
        transferEntries.contains { item in
            guard item.kind == .image else { return false }
            if item.fingerprint == fingerprint { return true }
            let url = item.payloadName.map { storageFolder(for: item).appendingPathComponent($0) } ?? item.firstFileURL
            guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return hash(data) == fingerprint
        }
    }

    func addDroppedImageToTransfer(_ data: Data, fileExtension: String = "png") {
        guard NSImage(data: data) != nil else {
            transferError = "无法读取拖入的图片。"
            return
        }
        let fingerprint = hash(data)
        guard !containsTransferImage(fingerprint: fingerprint) else { return }
        let ext = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"].contains(fileExtension.lowercased())
            ? fileExtension.lowercased() : "png"
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperClipboard-drop-\(UUID().uuidString).\(ext)")
        do { try data.write(to: temporaryURL, options: .atomic) }
        catch {
            transferError = "无法准备拖入的图片：\(error.localizedDescription)"
            return
        }
        let item = ClipboardEntry(id: UUID(), kind: .image, fingerprint: fingerprint,
            plainText: nil, filePaths: [temporaryURL.path], payloadName: nil, thumbnailName: nil,
            sourceAppName: "拖放导入", sourceBundleID: nil, createdAt: Date(),
            lastCopiedAt: Date(), copyCount: 1, isPinned: false)
        addToTransfer(item, recordDropInHistory: transferDropSavesHistory, imageData: data, temporaryURL: temporaryURL)
    }

    func addDroppedTextToTransfer(_ text: String) {
        guard !text.isEmpty else { return }
        let item = ClipboardEntry(id: UUID(), kind: .text, fingerprint: hash(Data(text.utf8)),
            plainText: text, filePaths: [], payloadName: nil, thumbnailName: nil,
            sourceAppName: "拖放导入", sourceBundleID: nil, createdAt: Date(),
            lastCopiedAt: Date(), copyCount: 1, isPinned: false)
        addToTransfer(item, recordDropInHistory: transferDropSavesHistory)
    }

    func addToTransfer(_ item: ClipboardEntry) {
        addToTransfer(item, recordDropInHistory: false)
    }

    private func addToTransfer(_ item: ClipboardEntry, recordDropInHistory: Bool,
                               imageData: Data? = nil, temporaryURL: URL? = nil) {
        guard !transferBusy, !notebookBusy, !isInTransfer(item) else {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            return
        }
        guard !transferLoadFailed else {
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            transferError = "请先恢复中转站目录中的 transfer.json，避免覆盖现有内容。"
            return
        }
        transferBusy = true
        transferSourceIDs.insert(item.id)
        let source = storageFolder(for: item)
        let destination = transferDirectory
        let id = UUID()
        let thumbnail = item.thumbnailName ?? (item.kind == .video ? "\(item.id.uuidString)-thumbnail.png" : nil)
        Task {
            defer {
                transferBusy = false
                transferSourceIDs.remove(item.id)
                if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
                if !item.isNotebookEntry && !item.isTransferEntry && !entries.contains(where: { $0.id == item.id }) {
                    removeFiles(for: item)
                }
                scheduleTransferCleanup()
            }
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try NotebookStorage.archive(id: id, sourceFolder: source, destination: destination,
                        filePaths: item.filePaths, payloadName: item.payloadName, thumbnailName: thumbnail,
                        requiresFiles: item.kind == .file || item.kind == .video, requiresImage: item.kind == .image)
                }.value
                var archived = item
                archived.id = id
                archived.isPinned = false
                archived.notebookFolderName = nil
                archived.transferFolderName = snapshot.directoryName
                archived.filePaths = snapshot.filePaths
                archived.payloadName = snapshot.payloadName
                archived.thumbnailName = snapshot.thumbnailName
                transferEntries.append(archived)
                do { try writeTransferState() }
                catch {
                    transferEntries.removeAll { $0.id == id }
                    try? FileManager.default.removeItem(at: destination.appendingPathComponent(snapshot.directoryName))
                    throw error
                }
                if archived.kind == .video { ensureVideoThumbnail(for: archived) }
                if recordDropInHistory {
                    let historyImageData = imageData ?? (item.kind == .image
                        ? item.firstFileURL.flatMap { self.imageData(from: $0) } : nil)
                    record(kind: item.kind, fingerprint: item.fingerprint, text: item.plainText,
                           paths: imageData == nil ? item.filePaths : [], payload: historyImageData,
                           payloadExtension: item.firstFileURL?.pathExtension,
                           thumbnail: nil, sourceName: item.sourceAppName, sourceID: nil)
                }
            } catch {
                transferError = "加入中转站失败：\(error.localizedDescription.replacingOccurrences(of: "记事本", with: "中转站"))"
            }
        }
    }

    func transferWindowDidOpen(at now: Date = Date()) {
        if !transferWindowVisible { clearExpiredTransfer(at: now) }
        transferCleanupTask?.cancel()
        transferCleanupTask = nil
        transferWindowVisible = true
        transferClosedAt = nil
        if !transferLoadFailed { persistTransfer() }
    }

    func transferWindowDidClose(at now: Date = Date()) {
        guard transferWindowVisible || transferClosedAt == nil else { return }
        transferWindowVisible = false
        transferClosedAt = now
        if !transferLoadFailed { persistTransfer() }
        scheduleTransferCleanup()
    }

    @discardableResult
    func clearExpiredTransfer(at now: Date = Date()) -> Bool {
        guard !transferWindowVisible, !transferBusy, !transferEntries.isEmpty,
              let closed = transferClosedAt,
              now.timeIntervalSince(closed) >= Double(transferClearMinutes) * 60 else { return false }
        return clearTransfer()
    }

    private func scheduleTransferCleanup() {
        transferCleanupTask?.cancel()
        transferCleanupTask = nil
        guard !transferWindowVisible, !transferEntries.isEmpty, let closed = transferClosedAt else { return }
        if clearExpiredTransfer() { return }
        let deadline = closed.addingTimeInterval(Double(transferClearMinutes) * 60)
        let delay = max(1, deadline.timeIntervalSinceNow)
        transferCleanupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.clearExpiredTransfer()
        }
    }

    @discardableResult
    func clearTransfer() -> Bool {
        guard !transferBusy, !transferLoadFailed else { return false }
        let previous = transferEntries
        let previousClosedAt = transferClosedAt
        transferEntries = []
        transferClosedAt = nil
        do { try writeTransferState() }
        catch {
            transferEntries = previous
            transferClosedAt = previousClosedAt
            transferError = "清空中转站失败：\(error.localizedDescription)"
            return false
        }
        transferCleanupTask?.cancel()
        transferCleanupTask = nil
        deleteTransferFiles(for: previous)
        return true
    }

    func removeFromTransfer(_ item: ClipboardEntry) {
        guard !transferBusy, !transferLoadFailed else { return }
        let previous = transferEntries
        transferEntries.removeAll { $0.id == item.id }
        do { try writeTransferState() }
        catch {
            transferEntries = previous
            transferError = "移出中转站失败：\(error.localizedDescription)"
            return
        }
        deleteTransferFiles(for: [item])
    }

    private func deleteTransferFiles(for items: [ClipboardEntry]) {
        let directories = items.compactMap { item in
            item.transferFolderName.map { transferDirectory.appendingPathComponent($0, isDirectory: true) }
        }
        Task.detached(priority: .utility) {
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func writeTransferState() throws {
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(TransferState(entries: transferEntries, closedAt: transferClosedAt))
            .write(to: transferDirectory.appendingPathComponent("transfer.json"), options: .atomic)
    }

    private func persistTransfer() {
        do { try writeTransferState() }
        catch { transferError = "保存中转站失败：\(error.localizedDescription)" }
    }

    func listPreviewRequest(for item: ClipboardEntry) -> ClipboardPreviewRequest {
        let directory = storageFolder(for: item)
        let thumbnail = item.thumbnailName
            ?? (item.kind == .image ? item.payloadName : nil)
            ?? (item.kind == .video ? "\(item.id.uuidString)-thumbnail.png" : nil)
        var imageURLs: [URL] = []
        if item.kind == .image || item.kind == .video {
            if let thumbnail { imageURLs.append(directory.appendingPathComponent(thumbnail)) }
            if item.kind == .image, let url = item.firstFileURL, !imageURLs.contains(url) { imageURLs.append(url) }
        }
        let key = "\(directory.path)|\(item.id)|\(previewRevisions[item.id, default: 0])|\(item.payloadName ?? "")|\(item.thumbnailName ?? "")"
        return ClipboardPreviewRequest(key: key,
            richTextURL: item.kind == .text ? item.payloadName.map { directory.appendingPathComponent($0) } : nil,
            imageURLs: imageURLs)
    }

    func loadListPreview(for item: ClipboardEntry, request: ClipboardPreviewRequest) async -> ClipboardPreview? {
        guard request.richTextURL != nil || !request.imageURLs.isEmpty else { return nil }
        let result = await ClipboardPreviewCache.shared.load(request)
        if !Task.isCancelled, item.kind == .video, result?.image == nil { ensureVideoThumbnail(for: item) }
        return result
    }

    func richText(for item: ClipboardEntry) -> NSAttributedString? {
        guard item.kind == .text, let name = item.payloadName,
              let data = try? Data(contentsOf: storageFolder(for: item).appendingPathComponent(name)) else { return nil }
        var documentAttributes: NSDictionary?
        guard let attributed = NSAttributedString(rtf: data, documentAttributes: &documentAttributes) else { return nil }
        let background = documentAttributes?[NSAttributedString.DocumentAttributeKey.backgroundColor]
            ?? documentAttributes?[NSAttributedString.DocumentAttributeKey.backgroundColor.rawValue]
        guard let background = background as? NSColor else { return attributed }
        let preview = NSMutableAttributedString(attributedString: attributed)
        preview.addAttribute(ClipboardTextAppearance.documentBackgroundKey, value: background,
                             range: NSRange(location: 0, length: preview.length))
        return preview
    }

    func thumbnail(for item: ClipboardEntry) -> NSImage? {
        let cachedName = item.thumbnailName
            ?? (item.kind == .image ? item.payloadName : nil)
            ?? (item.kind == .video ? "\(item.id.uuidString)-thumbnail.png" : nil)
        if let name = cachedName {
            if let image = NSImage(contentsOf: storageFolder(for: item).appendingPathComponent(name)) { return image }
        }
        if item.kind == .video { ensureVideoThumbnail(for: item) }
        if item.kind == .image, let url = item.firstFileURL {
            return NSImage(contentsOf: url)
        }
        if let url = item.firstFileURL, item.kind == .file {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func ensureVideoThumbnail(for item: ClipboardEntry) {
        // A notebook uses the thumbnail copied at archive time, or its own video.
        guard item.kind == .video, let url = item.firstFileURL,
              !pendingVideoThumbnails.contains(item.id), !failedVideoThumbnails.contains(item.id) else { return }
        let name = item.thumbnailName ?? "\(item.id.uuidString)-thumbnail.png"
        let destination = storageFolder(for: item).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        pendingVideoThumbnails.insert(item.id)
        Task { [weak self] in
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            let thumbnails = try? await VideoTool.thumbnailImages(
                for: AVURLAsset(url: url), at: [0], size: CGSize(width: 480, height: 320)
            )
            guard let self else { return }
            pendingVideoThumbnails.remove(item.id)
            let source = item.isTransferEntry ? transferEntries : (item.isNotebookEntry ? notebookEntries : entries)
            guard let current = source.first(where: { $0.id == item.id }),
                  let frame = thumbnails?.first,
                  let data = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else {
                failedVideoThumbnails.insert(item.id)
                return
            }
            do {
                try data.write(to: storageFolder(for: current).appendingPathComponent(name), options: .atomic)
                if item.isTransferEntry, let index = transferEntries.firstIndex(where: { $0.id == item.id }) {
                    transferEntries[index].thumbnailName = name
                    transferEntries[index].previewAspectRatio = CGFloat(frame.image.width) / CGFloat(frame.image.height)
                    persistTransfer()
                } else if item.isNotebookEntry, let index = notebookEntries.firstIndex(where: { $0.id == item.id }) {
                    notebookEntries[index].thumbnailName = name
                    notebookEntries[index].previewAspectRatio = CGFloat(frame.image.width) / CGFloat(frame.image.height)
                    persistNotebook()
                } else if let index = entries.firstIndex(where: { $0.id == item.id }) {
                    entries[index].thumbnailName = name
                    entries[index].previewAspectRatio = CGFloat(frame.image.width) / CGFloat(frame.image.height)
                    save()
                }
            } catch {
                failedVideoThumbnails.insert(item.id)
            }
        }
    }

    private func trimAndSave() {
        let unpinned = entries.filter { !$0.isPinned }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        for item in unpinned.dropFirst(maxEntries) {
            entries.removeAll { $0.id == item.id }
            removeFiles(for: item)
        }
        save()
    }

    private func removeFiles(for item: ClipboardEntry) {
        guard !item.isNotebookEntry, !item.isTransferEntry,
              !archivingHistoryIDs.contains(item.id), !transferSourceIDs.contains(item.id) else { return }
        previewRevisions.removeValue(forKey: item.id)
        let fallbackVideoThumbnail = item.kind == .video ? "\(item.id.uuidString)-thumbnail.png" : nil
        for name in [item.payloadName, item.thumbnailName, fallbackVideoThumbnail].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: folder.appendingPathComponent("history.json"), options: .atomic)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
