import AppKit

@main
struct TransferDragReceiverTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var policy = TransferDragHintPolicy()
        policy.begin(changeCount: 10)
        func visible(_ generation: Int, down: Bool = true, files: Bool = true, own: Bool = false, ready: Bool = true) -> Bool {
            policy.shouldShow(buttonDown: down, changeCount: generation, hasFiles: files, isTransfer: own, canAccept: ready)
        }
        precondition(!visible(10), "Retained URLs from an earlier drag must not show the hint")
        precondition(visible(11), "New external file drags must show the target")
        precondition(!visible(11, files: false), "Dragging text must not show a file target")
        precondition(!visible(11, own: true), "Shelf children and groups must not re-enter through the global target")
        precondition(!visible(11, ready: false), "Do not offer a destination while saving another group")
        precondition(!visible(11, down: false), "Mouse release must dismiss the target")
        policy.consume()
        precondition(!visible(12), "Late callbacks after a drop must not revive the target")
        policy.begin(changeCount: 12)
        precondition(!visible(12) && visible(13), "A fresh mouse gesture may show a new file session")
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 875),
                       NSRect(x: -1920, y: 100, width: 1920, height: 1055),
                       NSRect(x: 500, y: 900, width: 2560, height: 1400)]
        for screen in screens {
            let hint = TransferDragHintPolicy.frame(in: screen)
            precondition(screen.contains(hint))
            precondition(hint.maxX == screen.maxX - 16 && hint.maxY == screen.maxY - 16,
                         "Position relative to the selected display, including negative origins")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/first-drag-a.txt")
        let second = URL(fileURLWithPath: "/tmp/first-drag-b.png")
        board.writeObjects([first as NSURL, second as NSURL])
        let target = TransferDragDestination(frame: NSRect(x: 0, y: 0, width: 232, height: 88))
        target.canAccept = { true }
        var accepted: [[URL]] = []
        target.accept = { urls in accepted.append(urls); return true }
        precondition(target.hitTest(NSPoint(x: 120, y: 44)) === target,
                     "The hosting label must not intercept the first drag")
        precondition(target.registeredDraggedTypes.contains(.fileURL))
        precondition(target.beginTracking(board) == .copy && target.isTracking)
        precondition(target.performDrop(board) && accepted == [[first, second]],
                     "The first session must import the complete batch without a warm-up drag")
        precondition(!target.isTracking && !target.highlighted)
        precondition(target.beginTracking(board) == .copy)
        target.resetTracking()
        precondition(accepted.count == 1, "Leaving/cancelling must not import anything")
        target.canAccept = { false }
        precondition(target.beginTracking(board).isEmpty && !target.performDrop(board))
        precondition(accepted.count == 1)
        target.canAccept = { true }
        board.clearContents()
        board.setString("text", forType: .string)
        var plainText: String?
        target.acceptText = { text, _ in plainText = text; return true }
        precondition(target.beginTracking(board) == .copy && target.performDrop(board) && plainText == "text")
        board.clearContents()
        board.writeObjects([first as NSURL])
        board.setData(Data("own".utf8), forType: NSPasteboard.PasteboardType(ClipboardStore.transferDragTypeIdentifier))
        precondition(target.beginTracking(board).isEmpty && !target.performDrop(board))
        precondition(accepted.count == 1)
        board.clearContents()
        board.setString("https://example.com/photo.png?size=large", forType: .URL)
        precondition(TransferWebImageDrop.hasSupportedContent(board))
        var remote: URL?
        target.acceptImageURL = { remote = $0; return true }
        precondition(target.performDrop(board) && remote?.path == "/photo.png")
        board.clearContents()
        board.setString("https://example.com/article", forType: .URL)
        precondition(TransferWebImageDrop.hasSupportedContent(board))
        precondition(TransferWebImageDrop.imageURL(in: board) == nil, "Ordinary links must be saved as links, not downloaded as images")
        precondition(target.performDrop(board) && plainText == "https://example.com/article")
        board.clearContents()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:4, pixelsHigh:4, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
        let png = bitmap.representation(using:.png, properties:[:])!
        board.setData(png, forType: .png)
        var captured: Data?
        target.acceptImage = { data, _ in captured = data; return true }
        precondition(target.beginTracking(board) == .copy && target.performDrop(board) && captured == png)
        board.clearContents()
        board.setString("# WeChat Qt URI list\r\nfile:///tmp/sticker.gif\r\n", forType: NSPasteboard.PasteboardType("com.trolltech.anymime.text--uri-list"))
        precondition(TransferWebImageDrop.hasSupportedContent(board))
        precondition(TransferWebImageDrop.fileURLs(in: board) == [URL(fileURLWithPath: "/tmp/sticker.gif")])
        target.accept = { urls in urls == [URL(fileURLWithPath: "/tmp/sticker.gif")] }
        precondition(target.beginTracking(board) == .copy && target.performDrop(board))
        print("PASS: fresh file gesture detection, stale/text/internal/busy drag rejection, release/late callback reset and multi-display target placement")
    }
}
