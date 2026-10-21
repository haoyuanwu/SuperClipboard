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
    case recent = "最近复制", frequency = "复制次数"
    var id: String { rawValue }
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
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published var sortOrder: ClipboardSortOrder = .recent {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder") }
    }
    @Published var maxEntries: Int = 500 {
        didSet { UserDefaults.standard.set(maxEntries, forKey: "maxEntries"); trimAndSave() }
    }

    private let pasteboard = NSPasteboard.general
    private let folder: URL
    private var lastChangeCount: Int
    private var timer: Timer?
    private var pendingVideoThumbnails: Set<UUID> = []
    private var failedVideoThumbnails: Set<UUID> = []

    var sortedEntries: [ClipboardEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if sortOrder == .frequency && lhs.copyCount != rhs.copyCount { return lhs.copyCount > rhs.copyCount }
            return lhs.lastCopiedAt > rhs.lastCopiedAt
        }
    }

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperClipboard", isDirectory: true)
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
        if let raw = UserDefaults.standard.string(forKey: "sortOrder"), let order = ClipboardSortOrder(rawValue: raw) {
            sortOrder = order
        }
        if let count = UserDefaults.standard.object(forKey: "maxEntries") as? Int { maxEntries = count }
        for item in entries where item.kind == .video { ensureVideoThumbnail(for: item) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
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
            entries[index].copyCount += 1
            entries[index].lastCopiedAt = now
            entries[index].sourceAppName = sourceName
            entries[index].sourceBundleID = sourceID
            if let payload {
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
        trimAndSave()
        if kind == .video, let item = entries.first(where: { $0.id == id }) {
            ensureVideoThumbnail(for: item)
        }
    }

    func copy(_ item: ClipboardEntry) {
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            if let name = item.payloadName, let data = try? Data(contentsOf: folder.appendingPathComponent(name)) {
                pasteboard.setData(data, forType: .rtf)
            }
            pasteboard.setString(item.plainText ?? "", forType: .string)
        case .image:
            if let name = item.payloadName,
               let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
               let image = NSImage(data: data) {
                pasteboard.clearContents()
                pasteboard.writeObjects([image])
                break
            }
            if !item.filePaths.isEmpty {
                let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
                guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }
                pasteboard.clearContents()
                pasteboard.writeObjects(urls as [NSURL])
                break
            }
            return
        case .file, .video:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) }
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
        lastChangeCount = pasteboard.changeCount
        if let index = entries.firstIndex(where: { $0.id == item.id }) {
            entries[index].copyCount += 1
            entries[index].lastCopiedAt = Date()
            save()
        }
    }

    func togglePin(_ item: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
        entries[index].isPinned.toggle()
        save()
    }

    func delete(_ item: ClipboardEntry) {
        entries.removeAll { $0.id == item.id }
        removeFiles(for: item)
        save()
    }

    func clearUnpinned() {
        for item in entries where !item.isPinned { removeFiles(for: item) }
        entries.removeAll { !$0.isPinned }
        save()
    }

    func richText(for item: ClipboardEntry) -> NSAttributedString? {
        guard item.kind == .text, let name = item.payloadName,
              let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
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
            if let image = NSImage(contentsOf: folder.appendingPathComponent(name)) { return image }
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
        guard item.kind == .video, let url = item.firstFileURL,
              !pendingVideoThumbnails.contains(item.id), !failedVideoThumbnails.contains(item.id) else { return }
        let name = item.thumbnailName ?? "\(item.id.uuidString)-thumbnail.png"
        guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { return }
        pendingVideoThumbnails.insert(item.id)
        Task { [weak self] in
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            let thumbnails = try? await VideoTool.thumbnailImages(
                for: AVURLAsset(url: url), at: [0], size: CGSize(width: 480, height: 320)
            )
            guard let self else { return }
            pendingVideoThumbnails.remove(item.id)
            guard let frame = thumbnails?.first,
                  let data = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]),
                  let index = entries.firstIndex(where: { $0.id == item.id }) else {
                failedVideoThumbnails.insert(item.id)
                return
            }
            do {
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                entries[index].thumbnailName = name
                save()
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
