import Foundation

/// File operations stay off the main thread; each entry is committed as one directory.
enum NotebookStorage {
    struct Snapshot: Sendable {
        let directoryName: String
        let filePaths: [String]
        let payloadName: String?
        let thumbnailName: String?
    }

    enum StorageError: LocalizedError {
        case missingContent, destinationExists, nestedDestination, recursiveSource
        var errorDescription: String? {
            switch self {
            case .missingContent: "原文件已不存在，无法加入记事本。"
            case .destinationExists: "目标位置已有记事本目录，请选择其他位置。"
            case .nestedDestination: "请选择当前记事本目录之外的位置。"
            case .recursiveSource: "此文件夹包含记事本保存目录，请先更改保存位置。"
            }
        }
    }

    nonisolated static func archive(id: UUID, sourceFolder: URL, destination: URL,
                                    filePaths: [String], payloadName: String?, thumbnailName: String?,
                                    requiresFiles: Bool, requiresImage: Bool) throws -> Snapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let name = id.uuidString
        let final = destination.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else { throw StorageError.destinationExists }
        let staging = destination.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func copyCached(_ name: String?) throws -> String? {
            guard let name, fm.fileExists(atPath: sourceFolder.appendingPathComponent(name).path) else { return nil }
            try fm.copyItem(at: sourceFolder.appendingPathComponent(name), to: staging.appendingPathComponent(name))
            return name
        }
        let payload = try copyCached(payloadName)
        let thumbnail = thumbnailName == payloadName ? payload : try copyCached(thumbnailName)
        var storedPaths: [String] = []
        // Images already captured as bytes do not depend on their original file.
        if requiresFiles || (requiresImage && payload == nil) {
            guard !filePaths.isEmpty else { throw StorageError.missingContent }
            for (index, path) in filePaths.enumerated() {
                let source = URL(fileURLWithPath: path)
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                guard fm.fileExists(atPath: source.path) else { throw StorageError.missingContent }
                let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory)
                if isDirectory.boolValue, staging.resolvingSymlinksInPath().path.hasPrefix(resolvedSource.path + "/") {
                    throw StorageError.recursiveSource
                }
                let relative = "files/\(index)/\(source.lastPathComponent)"
                let target = staging.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try fm.copyItem(at: resolvedSource, to: target) }
                catch {
                    let failure = error as NSError
                    let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
                    let permissionFailure = (failure.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(failure.code))
                        || (failure.domain == NSPOSIXErrorDomain && [1, 13].contains(failure.code))
                        || (underlying?.domain == NSPOSIXErrorDomain && [1, 13].contains(underlying?.code ?? 0))
                    guard permissionFailure, !isDirectory.boolValue else { throw error }
                    // Some downloads permit reading bytes but prohibit copying their
                    // metadata/ACL. Copy only regular-file contents, in bounded chunks.
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try copyFileContents(from: resolvedSource, to: target)
                }
                storedPaths.append(final.appendingPathComponent(relative).path)
            }
        } else if requiresImage, let payload {
            // Preserve the displayed filename while copying the captured image bytes.
            let filename = filePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "图片.\(URL(fileURLWithPath: payload).pathExtension)"
            let relative = "files/0/\(filename)"
            let target = staging.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: staging.appendingPathComponent(payload), to: target)
            storedPaths = [final.appendingPathComponent(relative).path]
        }
        try fm.moveItem(at: staging, to: final)
        return Snapshot(directoryName: name, filePaths: storedPaths, payloadName: payload, thumbnailName: thumbnail)
    }

    nonisolated static func copyFileContents(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
        }
        var complete = false
        defer { if !complete { try? fm.removeItem(at: target) } }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var copied = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
            copied += chunk.count
        }
        guard copied == values.fileSize else { throw CocoaError(.fileReadCorruptFile) }
        try output.synchronize()
        complete = true
    }

    nonisolated static func relocate(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let old = source.resolvingSymlinksInPath().standardizedFileURL.path
        let new = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard new != old, !new.hasPrefix(old + "/"), !old.hasPrefix(new + "/") else { throw StorageError.nestedDestination }
        guard !fm.fileExists(atPath: destination.path) else { throw StorageError.destinationExists }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".notebook-migration-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        if fm.fileExists(atPath: source.path) {
            try fm.copyItem(at: source, to: staging)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try fm.moveItem(at: staging, to: destination)
    }
}
