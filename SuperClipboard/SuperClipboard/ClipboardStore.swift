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

enum TransferFolderDropBehavior: String, CaseIterable, Identifiable {
    case ask, groupContents, keepFolder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: "每次询问"
        case .groupContents: "将文件夹内容添加成组"
        case .keepFolder: "保留整个文件夹"
        }
    }
}

struct TransferFolderDropDecision {
    let behavior: TransferFolderDropBehavior
    let remember: Bool
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
    var fileGroupName: String? = nil
    var webImageCacheName: String? = nil
    var sourceFilePaths: [String]? = nil

    var isFileGroup: Bool { (kind == .file || kind == .video) && (filePaths.count > 1 || fileGroupName != nil) }

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

struct EntryAvailability: Equatable, Sendable {
    var missing = 0
    var total = 0
    var isMissing: Bool { total > 0 && missing == total }
    var isPartial: Bool { missing > 0 && !isMissing }
}

enum CleanupScope { case history, transfer }

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var availability: [UUID: EntryAvailability] = [:]
    @Published var availabilityError: String?
    private var scanningAvailability = false

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
    @Published private(set) var transferDropLoading = false
    private(set) var transferDropCancelled = false
    private(set) var transferDragIsInternal = false
    func beginInternalTransferDrag() { transferDragIsInternal = true }
    func beginExternalDragGesture() { transferDragIsInternal = false }
    @Published private(set) var transferWindowVisible = false
    @Published private(set) var transferClosedAt: Date?
    @Published var transferError: String?
    @Published var dragError: String?
    @Published var transferFolderDropBehavior: TransferFolderDropBehavior = .ask {
        didSet { defaults.set(transferFolderDropBehavior.rawValue, forKey: "transferFolderDropBehavior") }
    }
    /// Replaceable for tests; production uses a native, explicitly cancellable confirmation.
    var folderDropConfirmation: ([URL]) async -> TransferFolderDropDecision? = { folders in
        let alert = NSAlert()
        alert.messageText = "将文件夹内容添加成组？"
        let names = folders.prefix(3).map(\.lastPathComponent).joined(separator: "、")
        alert.informativeText = "\(names)\n添加成组会收集文件夹第一层内容，子文件夹保留完整；也可以保留整个文件夹。空文件夹会完整保留。"
        alert.addButton(withTitle: "添加成组")
        alert.addButton(withTitle: "保留文件夹")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "下次不再询问"
        alert.window.level = .modalPanel
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return nil }
        return TransferFolderDropDecision(behavior: response == .alertFirstButtonReturn ? .groupContents : .keepFolder,
                                          remember: alert.suppressionButton?.state == .on)
    }
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
        transferFolderDropBehavior = TransferFolderDropBehavior(rawValue: defaults.string(forKey: "transferFolderDropBehavior") ?? "") ?? .ask
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

    func contentAvailability(for item: ClipboardEntry) -> EntryAvailability {
        availability[item.id] ?? EntryAvailability()
    }

    nonisolated private static func inspect(_ item: ClipboardEntry, directory: URL) -> EntryAvailability {
        let fm = FileManager.default
        func readable(_ url: URL) -> Bool { fm.isReadableFile(atPath: url.path) }
        if item.kind == .text {
            let usable = item.plainText?.isEmpty == false || item.payloadName.map { readable(directory.appendingPathComponent($0)) } == true
            return EntryAvailability(missing: usable ? 0 : 1, total: 1)
        }
        if item.kind == .image, let name = item.payloadName, readable(directory.appendingPathComponent(name)) {
            return EntryAvailability(missing: 0, total: 1)
        }
        let count = max(1, item.filePaths.count)
        let existing = item.filePaths.filter { fm.isReadableFile(atPath: $0) }.count
        return EntryAvailability(missing: count - existing, total: count)
    }

    @discardableResult
    func checkAvailability(_ item: ClipboardEntry) -> EntryAvailability {
        let status = Self.inspect(item, directory: storageFolder(for: item))
        if availability[item.id] != status { availability[item.id] = status }
        return status
    }

    func refreshAvailability() async {
        guard !scanningAvailability else { return }
        scanningAvailability = true
        defer { scanningAvailability = false }
        let snapshots = (entries + transferEntries + notebookEntries).map { ($0, storageFolder(for: $0)) }
        let result = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: snapshots.map { ($0.0.id, Self.inspect($0.0, directory: $0.1)) })
        }.value
        guard !Task.isCancelled else { return }
        if availability != result { availability = result }
    }

    func unavailableCount(in scope: CleanupScope) -> Int {
        let items = scope == .history ? entries : transferEntries
        return items.filter { !$0.isPinned && contentAvailability(for: $0).isMissing }.count
    }

    func cleanUnavailable(in scope: CleanupScope) {
        guard !transferBusy, !transferDropLoading, !notebookBusy else { return }
        availabilityError = nil
        let items = scope == .history ? entries : transferEntries
        // Recheck immediately: a disconnected disk may have become available again.
        let removed = items.filter { !$0.isPinned && checkAvailability($0).isMissing }
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        if scope == .history {
            let remaining = entries.filter { !ids.contains($0.id) }
            do {
                try JSONEncoder().encode(remaining).write(to: folder.appendingPathComponent("history.json"), options: .atomic)
                entries = remaining
                for item in removed { removeFiles(for: item) }
            } catch { availabilityError = "清理失败，记录已保留：\(error.localizedDescription)"; return }
        } else {
            guard !transferLoadFailed else { return }
            let previous = transferEntries
            transferEntries.removeAll { ids.contains($0.id) }
            do { try writeTransferState() }
            catch {
                transferEntries = previous
                availabilityError = "清理失败，记录已保留：\(error.localizedDescription)"
                return
            }
            deleteTransferFiles(for: removed)
        }
        availability = availability.filter { !ids.contains($0.key) }
    }

    @discardableResult
    func copy(_ item: ClipboardEntry) -> Bool {
        guard !checkAvailability(item).isMissing else {
            availabilityError = "内容文件已被移动、删除或暂时无法访问，剪贴板内容未更改。"
            return false
        }
        switch item.kind {
        case .text:
            let text = item.plainText ?? richText(for: item)?.string ?? ""
            guard !text.isEmpty else { return false }
            pasteboard.clearContents()
            if let name = item.payloadName, let data = try? Data(contentsOf: storageFolder(for: item).appendingPathComponent(name)) {
                pasteboard.setData(data, forType: .rtf)
            }
            guard pasteboard.setString(text, forType: .string) else { return false }
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
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.isReadableFile(atPath: $0.path) }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        }
        recordCopy(of: item)
        return true
    }

    private func recordCopy(of item: ClipboardEntry) {
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
        panel.message = "将在所选位置创建 口袋Cube 记事本 文件夹，并迁移已有记事本。"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        changeNotebookDirectory(to: parent.appendingPathComponent("口袋Cube 记事本", isDirectory: true))
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
        func paths(_ entry: ClipboardEntry) -> Set<String> {
            Set((entry.sourceFilePaths ?? entry.filePaths).map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
            })
        }
        return transferEntries.contains { saved in
            if saved.id == item.id { return true }
            if !item.filePaths.isEmpty, item.webImageCacheName == nil,
               let sourcePaths = saved.sourceFilePaths, !sourcePaths.isEmpty {
                return paths(saved) == paths(item)
            }
            if saved.sourceFilePaths == nil, !item.filePaths.isEmpty, item.kind != .image {
                let joined = paths(item).sorted().joined(separator: "\u{0}")
                if saved.fingerprint == hash(Data((item.kind.rawValue + joined).utf8))
                    || saved.fingerprint == hash(Data(("folder-group" + joined).utf8)) { return true }
            }
            return saved.fingerprint == item.fingerprint ||
                (item.kind == .text && saved.kind == .text && saved.plainText == item.plainText)
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
        guard !checkAvailability(item).isMissing else {
            dragError = "内容文件已被移动、删除或暂时无法访问。可恢复原文件，或清理失效记录。"
            return nil
        }
        let paths = item.filePaths.filter { FileManager.default.isReadableFile(atPath: $0) }
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
            } else if paths.count == 1 {
                url = URL(fileURLWithPath: paths[0])
            } else if paths.count > 1 {
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

    /// Resolve against the current group, never a stale or caller-provided path.
    private func transferFileURL(_ path: String, in group: ClipboardEntry) -> URL? {
        guard let current = transferEntries.first(where: { $0.id == group.id }),
              current.isFileGroup, current.filePaths.contains(path) else { return nil }
        guard FileManager.default.isReadableFile(atPath: path) else {
            _ = checkAvailability(current)
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    func copyTransferFile(_ path: String, in group: ClipboardEntry) -> Bool {
        guard let url = transferFileURL(path, in: group) else {
            availabilityError = "这个文件已被移除或暂时无法访问，剪贴板内容未更改。"
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { return false }
        recordCopy(of: group)
        return true
    }

    func transferFileDragProvider(_ path: String, in group: ClipboardEntry) -> NSItemProvider? {
        guard let url = transferFileURL(path, in: group) else {
            dragError = "这个文件已被移除或暂时无法访问，无法拖出。"
            return nil
        }
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        // The child remains part of this shelf: dragging it back is not an import.
        return markTransferDrag(provider, item: group)
    }

    private func transferDragFolder(for item: ClipboardEntry) throws -> URL {
        let fm = FileManager.default
        let directory = item.isTransferEntry || item.isNotebookEntry
            ? storageFolder(for: item)
            : fm.temporaryDirectory.appendingPathComponent("SuperClipboard-DragExports", isDirectory: true)
                .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let output = directory.appendingPathComponent("拖出文件", isDirectory: true)
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            for (index, path) in item.filePaths.filter({ fm.isReadableFile(atPath: $0) }).enumerated() {
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

    /// Resolve every provider before importing the group. Temporary representations
    /// are copied inside their callbacks, before the system removes them.
    /// Keep the native URLs and their access scope alive until the independent copy finishes.
    func acceptTransferURLs(_ urls: [URL]) -> Bool {
        guard !transferDragIsInternal, !transferBusy, !transferDropLoading, !notebookBusy, !urls.isEmpty,
              urls.allSatisfy(\.isFileURL) else { return false }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        transferDropLoading = true
        transferDropCancelled = false
        transferError = nil
        Task {
            defer {
                for url in scoped { url.stopAccessingSecurityScopedResource() }
                transferDropLoading = false
            }
            do {
                guard let plan = try await prepareTransferFolderDrop(urls) else {
                    transferDropCancelled = true
                    return
                }
                addDroppedFilesToTransfer(plan.urls, groupName: plan.groupName)
                while transferBusy { try await Task.sleep(for: .milliseconds(10)) }
            } catch { transferError = "无法读取拖入的文件：\(error.localizedDescription)" }
        }
        return true
    }

    func acceptTransferFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !transferDragIsInternal, !transferBusy, !transferDropLoading, !notebookBusy, !providers.isEmpty,
              !Self.isTransferDrag(providers) else { return false }
        let types = providers.map { provider -> String? in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
            return provider.registeredTypeIdentifiers.first { identifier in
                guard let type = UTType(identifier) else { return false }
                if type.conforms(to: .text), URL(fileURLWithPath: provider.suggestedName ?? "").pathExtension.isEmpty { return false }
                return type.conforms(to: .data) || type.conforms(to: .content)
            }
        }
        guard types.allSatisfy({ $0 != nil }) else { return false }
        transferDropLoading = true
        transferDropCancelled = false
        transferError = nil
        let staging = folder.appendingPathComponent("DropImports", isDirectory: true).appendingPathComponent(UUID().uuidString)
        Task {
            defer {
                transferDropLoading = false
                if !entries.contains(where: { $0.filePaths.contains(where: { $0.hasPrefix(staging.path + "/") }) }) {
                    try? FileManager.default.removeItem(at: staging)
                }
            }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var urls: [URL] = []
                for (index, provider) in providers.enumerated() {
                    let type = types[index]!
                    let loaded: [URL] = try await withCheckedThrowingContinuation { continuation in
                        if type == UTType.fileURL.identifier {
                            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                                if let error { continuation.resume(throwing: error); return }
                                let values = (value as? [Any]) ?? value.map { [$0] } ?? []
                                let urls = values.compactMap { value -> URL? in
                                    if let url = value as? URL { return url.isFileURL ? url : nil }
                                    if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL { return url }
                                    if let string = value as? String, let url = URL(string: string), url.isFileURL { return url }
                                    return nil
                                }
                                guard !urls.isEmpty, urls.count == values.count else {
                                    continuation.resume(throwing: CocoaError(.fileReadCorruptFile)); return
                                }
                                continuation.resume(returning: urls)
                            }
                        } else {
                            let directory = staging.appendingPathComponent(String(index))
                            let suggestedName = provider.suggestedName
                            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                                do {
                                    if let error { throw error }
                                    guard let url else { throw CocoaError(.fileReadUnknown) }
                                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                    var name = URL(fileURLWithPath: suggestedName ?? url.lastPathComponent).lastPathComponent
                                    if URL(fileURLWithPath: name).pathExtension.isEmpty,
                                       let ext = UTType(type)?.preferredFilenameExtension { name += "." + ext }
                                    let destination = directory.appendingPathComponent(name)
                                    try FileManager.default.copyItem(at: url, to: destination)
                                    continuation.resume(returning: [destination])
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                    }
                    urls.append(contentsOf: loaded)
                }
                guard let plan = try await prepareTransferFolderDrop(urls) else {
                    transferDropCancelled = true
                    return
                }
                addDroppedFilesToTransfer(plan.urls, groupName: plan.groupName)
                while transferBusy { try await Task.sleep(for: .milliseconds(10)) }
            } catch {
                transferError = "无法读取拖入的文件：\(error.localizedDescription)"
            }
        }
        return true
    }

    private func prepareTransferFolderDrop(_ urls: [URL]) async throws -> (urls: [URL], groupName: String?)? {
        var seen = Set<String>()
        let urls = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
        let shelfPath = transferDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard !urls.contains(where: { $0.path == shelfPath || $0.path.hasPrefix(shelfPath + "/") }) else { return nil }
        let folders = try urls.filter { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values.isDirectory == true && values.isPackage != true
        }
        guard !folders.isEmpty else { return (urls, nil) }
        var behavior = transferFolderDropBehavior
        if behavior == .ask {
            guard let decision = await folderDropConfirmation(folders), decision.behavior != .ask else { return nil }
            behavior = decision.behavior
            if decision.remember { transferFolderDropBehavior = behavior }
        }
        guard behavior == .groupContents else { return (urls, nil) }
        let folderPaths = Set(folders.map(\.path))
        let expanded = try await Task.detached(priority: .userInitiated) {
            try urls.flatMap { url -> [URL] in
                guard folderPaths.contains(url.path) else { return [url] }
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                return children.isEmpty ? [url] : children
            }
        }.value
        let name = folders.count == 1 && urls.count == 1 ? folders[0].lastPathComponent : "文件夹内容组"
        return (expanded, name)
    }

    func addDroppedFilesToTransfer(_ urls: [URL], groupName: String? = nil) {
        guard !transferDragIsInternal, !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return }
        var seen = Set<String>()
        let uniqueURLs = urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
        // A destination may strip our private drag marker. Staged payloads and
        // exported file groups still belong to this shelf and must not re-enter.
        let shelfPath = transferDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard !uniqueURLs.contains(where: { $0.path == shelfPath || $0.path.hasPrefix(shelfPath + "/") }) else { return }
        let kind: EntryKind
        if groupName == nil, uniqueURLs.count == 1, let type = UTType(filenameExtension: uniqueURLs[0].pathExtension) {
            kind = type.conforms(to: .image) ? .image : (type.conforms(to: .movie) ? .video : .file)
        } else {
            kind = .file
        }
        let paths = uniqueURLs.map(\.path)
        let fingerprint: String
        // Local file identity is its normalized source path, including images.
        fingerprint = hash(Data(("source-files|" + paths.sorted().joined(separator: "\u{0}")).utf8))
        let item = ClipboardEntry(id: UUID(), kind: kind, fingerprint: fingerprint,
            plainText: nil, filePaths: paths, payloadName: nil, thumbnailName: nil,
            sourceAppName: "拖放导入", sourceBundleID: nil, createdAt: Date(),
            lastCopiedAt: Date(), copyCount: 1, isPinned: false, fileGroupName: groupName)
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

    func addDroppedImageToTransfer(_ data: Data, fileExtension: String = "png", isWebImage: Bool = false) {
        guard !transferDragIsInternal, !transferBusy, !transferDropLoading, !notebookBusy, !transferLoadFailed else { return }
        guard NSImage(data: data) != nil else {
            transferError = "无法读取拖入的图片。"
            return
        }
        let fingerprint = hash(data)
        guard !containsTransferImage(fingerprint: fingerprint) else { return }
        let ext = ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"].contains(fileExtension.lowercased())
            ? fileExtension.lowercased() : "png"
        let cacheDirectory = isWebImage ? folder.appendingPathComponent("tmp", isDirectory: true) : FileManager.default.temporaryDirectory
        let temporaryURL = cacheDirectory.appendingPathComponent("SuperClipboard-drop-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: temporaryURL, options: .atomic)
        }
        catch {
            transferError = "无法准备拖入的图片：\(error.localizedDescription)"
            return
        }
        let item = ClipboardEntry(id: UUID(), kind: .image, fingerprint: fingerprint,
            plainText: nil, filePaths: [temporaryURL.path], payloadName: nil, thumbnailName: nil,
            sourceAppName: "拖放导入", sourceBundleID: nil, createdAt: Date(),
            lastCopiedAt: Date(), copyCount: 1, isPinned: false, webImageCacheName: isWebImage ? temporaryURL.lastPathComponent : nil)
        addToTransfer(item, recordDropInHistory: transferDropSavesHistory, imageData: data, temporaryURL: isWebImage ? nil : temporaryURL)
    }

    func addDroppedTextToTransfer(_ text: String, rtfData: Data? = nil) {
        guard !transferDragIsInternal, !transferBusy, !notebookBusy, !transferLoadFailed, !text.isEmpty else { return }
        var payload: String?
        if let rtfData {
            let name = "\(UUID().uuidString)-drop.rtf"
            do { try rtfData.write(to: folder.appendingPathComponent(name), options: .atomic); payload = name }
            catch { transferError = "无法保存拖入的富文本：\(error.localizedDescription)"; return }
        }
        let item = ClipboardEntry(id: UUID(), kind: .text, fingerprint: hash(Data(text.utf8)),
            plainText: text, filePaths: [], payloadName: payload, thumbnailName: nil,
            sourceAppName: "拖放导入", sourceBundleID: nil, createdAt: Date(),
            lastCopiedAt: Date(), copyCount: 1, isPinned: false)
        if isInTransfer(item) {
            if let payload { try? FileManager.default.removeItem(at: folder.appendingPathComponent(payload)) }
            return
        }
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
                if let name = item.webImageCacheName,
                   !transferEntries.contains(where: { $0.webImageCacheName == name }) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("tmp").appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent))
                }
                transferSourceIDs.remove(item.id)
                if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
                if !item.isNotebookEntry && !item.isTransferEntry && !entries.contains(where: { $0.id == item.id }) {
                    removeFiles(for: item)
                }
                scheduleTransferCleanup()
            }
            do {
                let snapshot = try await archiveTransferWithAuthorization(item: item, id: id, source: source,
                                                                          destination: destination, thumbnail: thumbnail)
                var archived = item
                archived.id = id
                archived.isPinned = false
                archived.notebookFolderName = nil
                archived.transferFolderName = snapshot.directoryName
                archived.sourceFilePaths = item.sourceFilePaths ?? (item.webImageCacheName == nil ? item.filePaths : [])
                archived.filePaths = snapshot.filePaths
                archived.payloadName = snapshot.payloadName
                archived.thumbnailName = snapshot.thumbnailName
                let previousClosedAt = transferClosedAt
                // A newly saved item starts its own retention interval. A stale
                // close time from an empty shelf must not delete this first drop.
                if !transferWindowVisible { transferClosedAt = Date() }
                transferEntries.append(archived)
                do { try writeTransferState() }
                catch {
                    transferClosedAt = previousClosedAt
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

    private func archiveTransferWithAuthorization(item: ClipboardEntry, id: UUID, source: URL,
                                                  destination: URL, thumbnail: String?) async throws -> NotebookStorage.Snapshot {
        func archive() async throws -> NotebookStorage.Snapshot {
            try await Task.detached(priority: .userInitiated) {
                try NotebookStorage.archive(id: id, sourceFolder: source, destination: destination,
                    filePaths: item.filePaths, payloadName: item.payloadName, thumbnailName: thumbnail,
                    requiresFiles: item.kind == .file || item.kind == .video, requiresImage: item.kind == .image)
            }.value
        }
        do { return try await archive() }
        catch {
            let failure = error as NSError
            let cause = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            let denied = (failure.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(failure.code))
                || (failure.domain == NSPOSIXErrorDomain && [1, 13].contains(failure.code))
                || (cause?.domain == NSPOSIXErrorDomain && [1, 13].contains(cause?.code ?? 0))
            // Ask only for source access, never modify permissions or write into a source folder.
            guard denied, !item.filePaths.isEmpty,
                  item.filePaths.contains(where: { path in
                      guard FileManager.default.isReadableFile(atPath: path) else { return true }
                      var directory: ObjCBool = false
                      FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                      if directory.boolValue { return false }
                      do {
                          let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                          try handle.close()
                          return false
                      } catch { return true }
                  }) else { throw error }
            let panel = NSOpenPanel()
            panel.title = "允许口袋Cube读取拖入的文件"
            panel.message = "源文件位于微信等应用的受保护目录。请选择刚才拖入的文件，授权后将重试保存中转副本。"
            panel.prompt = "授权并重试"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = item.filePaths.count > 1
            panel.directoryURL = URL(fileURLWithPath: item.filePaths[0]).deletingLastPathComponent()
            panel.nameFieldStringValue = URL(fileURLWithPath: item.filePaths[0]).lastPathComponent
            panel.level = .modalPanel
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                              userInfo: [NSLocalizedDescriptionKey: "已取消文件读取授权，未加入中转站。"])
            }
            let required = Set(item.filePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path })
            let selected = Set(panel.urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
            guard required.isSubset(of: selected) else {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                              userInfo: [NSLocalizedDescriptionKey: "请选择刚才拖入的原文件，或先将文件另存到下载文件夹再拖入。"])
            }
            let scoped = panel.urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
            return try await archive()
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
        guard !transferWindowVisible, !transferBusy, !transferDropLoading, !transferEntries.isEmpty,
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
        } + items.compactMap { item in
            item.webImageCacheName.map { folder.appendingPathComponent("tmp").appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
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
        let state = availability[item.id, default: EntryAvailability()]
        let key = "\(state.missing)/\(state.total)|\(directory.path)|\(item.id)|\(previewRevisions[item.id, default: 0])|\(item.payloadName ?? "")|\(item.thumbnailName ?? "")"
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
        let imports = folder.appendingPathComponent("DropImports").path + "/"
        for path in item.filePaths where path.hasPrefix(imports) {
            let relative = String(path.dropFirst(imports.count))
            guard let directory = relative.split(separator: "/").first else { continue }
            let destination = folder.appendingPathComponent("DropImports").appendingPathComponent(String(directory))
            if !entries.contains(where: { $0.id != item.id && $0.filePaths.contains(where: { $0.hasPrefix(destination.path + "/") }) }) {
                try? FileManager.default.removeItem(at: destination)
            }
        }
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
