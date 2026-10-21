import Foundation

@main
struct NotebookStorageTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("NotebookTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let history = root.appendingPathComponent("History")
        let notebook = root.appendingPathComponent("Notebook")
        try fm.createDirectory(at: history, withIntermediateDirectories: true)
        let payload = Data("captured image bytes".utf8)
        try payload.write(to: history.appendingPathComponent("capture.png"))
        let image = try NotebookStorage.archive(id: UUID(), sourceFolder: history, destination: notebook,
            filePaths: [root.appendingPathComponent("already-deleted/照片.png").path],
            payloadName: "capture.png", thumbnailName: nil, requiresFiles: false, requiresImage: true)
        precondition(URL(fileURLWithPath: image.filePaths[0]).lastPathComponent == "照片.png")
        try fm.removeItem(at: history.appendingPathComponent("capture.png"))
        precondition(tryData(image.filePaths[0]) == payload, "Image must survive cache and source deletion")

        let rtf = Data("{\\rtf1 formatted text}".utf8)
        try rtf.write(to: history.appendingPathComponent("text.rtf"))
        let text = try NotebookStorage.archive(id: UUID(), sourceFolder: history, destination: notebook,
            filePaths: [], payloadName: "text.rtf", thumbnailName: nil, requiresFiles: false, requiresImage: false)
        try fm.removeItem(at: history.appendingPathComponent("text.rtf"))
        precondition(tryData(notebook.appendingPathComponent(text.directoryName).appendingPathComponent(text.payloadName!).path) == rtf)

        let sources = root.appendingPathComponent("Sources")
        let first = sources.appendingPathComponent("a/report.txt")
        let second = sources.appendingPathComponent("b/report.txt")
        for url in [first, second] { try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let files = try NotebookStorage.archive(id: UUID(), sourceFolder: history, destination: notebook,
            filePaths: [first.path, second.path], payloadName: nil, thumbnailName: nil, requiresFiles: true, requiresImage: false)
        try fm.removeItem(at: sources)
        precondition(files.filePaths.count == 2 && files.filePaths[0] != files.filePaths[1])
        precondition(tryData(files.filePaths[0]) == Data("first".utf8))
        precondition(tryData(files.filePaths[1]) == Data("second".utf8))

        let video = root.appendingPathComponent("原视频.mov")
        try Data("video content".utf8).write(to: video)
        try Data("thumbnail bytes".utf8).write(to: history.appendingPathComponent("thumb.png"))
        let savedVideo = try NotebookStorage.archive(id: UUID(), sourceFolder: history, destination: notebook,
            filePaths: [video.path], payloadName: nil, thumbnailName: "thumb.png", requiresFiles: true, requiresImage: false)
        try fm.removeItem(at: video)
        precondition(tryData(savedVideo.filePaths[0]) == Data("video content".utf8))
        precondition(savedVideo.thumbnailName == "thumb.png")

        let count = try fm.contentsOfDirectory(atPath: notebook.path).count
        do {
            _ = try NotebookStorage.archive(id: UUID(), sourceFolder: history, destination: notebook,
                filePaths: [files.filePaths[0], root.appendingPathComponent("missing.mov").path],
                payloadName: nil, thumbnailName: nil, requiresFiles: true, requiresImage: false)
            preconditionFailure("Missing files must fail atomically")
        } catch NotebookStorage.StorageError.missingContent { }
        let remainingCount = try fm.contentsOfDirectory(atPath: notebook.path).count
        precondition(remainingCount == count, "No partial archive should remain")
        do {
            _ = try NotebookStorage.archive(id: UUID(), sourceFolder: history, destination: notebook,
                filePaths: [root.path], payloadName: nil, thumbnailName: nil, requiresFiles: true, requiresImage: false)
            preconditionFailure("A directory containing the notebook must not recursively archive itself")
        } catch NotebookStorage.StorageError.recursiveSource { }

        let migrated = root.appendingPathComponent("Moved Notebook")
        try NotebookStorage.relocate(from: notebook, to: migrated)
        try fm.removeItem(at: notebook)
        let relocatedImage = migrated.appendingPathComponent(String(image.filePaths[0].dropFirst(notebook.path.count + 1)))
        precondition(tryData(relocatedImage.path) == payload, "Migration must preserve the archived data")
        do {
            try NotebookStorage.relocate(from: migrated, to: migrated.appendingPathComponent("nested"))
            preconditionFailure("Nested migrations must be rejected")
        } catch NotebookStorage.StorageError.nestedDestination { }
        let existing = root.appendingPathComponent("Existing")
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("sentinel"))
        do {
            try NotebookStorage.relocate(from: migrated, to: existing)
            preconditionFailure("Existing destinations must be preserved")
        } catch NotebookStorage.StorageError.destinationExists { }
        precondition(tryData(existing.appendingPathComponent("sentinel").path) == Data("keep".utf8))
        print("PASS: image, rich text, same-name files, video, rollback, migration, recursive path and destination protection")
    }

    static func tryData(_ path: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: path)) }
}
