import AppKit
import Foundation

@main
struct ClipboardCaptureTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipboardCapture.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            board.releaseGlobally()
        }
        let store = ClipboardStore(storageDirectory: root, defaults: defaults,
                                   pasteboard: board, observesPasteboard: false)
        func capture(_ text: String, type: NSPasteboard.PasteboardType = .string) {
            board.clearContents()
            board.setString(text, forType: type)
            store.checkPasteboard()
        }
        capture("浏览器复制的普通文字\n第二行")
        precondition(store.entries.last?.plainText == "浏览器复制的普通文字\n第二行")
        store.checkPasteboard()
        precondition(store.entries.last?.copyCount == 1)
        capture("浏览器复制的普通文字\n第二行")
        precondition(store.entries.last?.copyCount == 2)
        capture("<html><body><p>网页富文本</p></body></html>", type: .html)
        precondition(store.entries.last?.plainText?.contains("网页富文本") == true)
        let rich = NSAttributedString(string: "只有 RTF 的文字")
        board.clearContents()
        board.setData(try rich.data(from: NSRange(location: 0, length: rich.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        store.checkPasteboard()
        precondition(store.entries.last?.plainText == rich.string)
        capture("https://example.com", type: .URL)
        precondition(store.entries.last?.plainText == "https://example.com")
        let count = store.entries.count
        capture(" \n\t  ")
        precondition(store.entries.count == count, "Whitespace-only text is skipped")
        capture("  保留文字前后的空白\n")
        precondition(store.entries.last?.plainText == "  保留文字前后的空白\n")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        board.clearContents()
        board.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png)
        store.checkPasteboard()
        precondition(store.entries.last?.kind == .image)
        for (name, kind) in [("sample.txt", EntryKind.file), ("sample.mp4", .video)] {
            let url = root.appendingPathComponent(name)
            try Data().write(to: url)
            board.clearContents()
            board.writeObjects([url as NSURL])
            store.checkPasteboard()
            precondition(store.entries.last?.kind == kind)
            precondition(store.entries.last?.filePaths == [url.path])
        }
        capture("启动前已经复制的文字")
        let startup = ClipboardStore(storageDirectory: root.appendingPathComponent("startup"), defaults: defaults,
                                     pasteboard: board)
        precondition(startup.entries.first?.plainText == "启动前已经复制的文字")
        let restored = ClipboardStore(storageDirectory: root, defaults: defaults,
                                      pasteboard: board, observesPasteboard: false)
        precondition(restored.entries.count == store.entries.count)
        print("Clipboard capture tests passed")
    }
}
