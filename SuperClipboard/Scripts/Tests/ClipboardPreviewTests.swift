import AppKit
import Foundation

@main
struct ClipboardPreviewTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardPreviewTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 3072,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = bitmap.representation(using: .png, properties: [:])!
        let imageURL = root.appendingPathComponent("large.png")
        try png.write(to: imageURL)
        let string = String(repeating: "富文本预览 👩‍👩‍👧‍👧\n", count: 3000)
        let rich = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.red, .backgroundColor: NSColor.white])
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
        let rtfURL = root.appendingPathComponent("text.rtf")
        try rtf.write(to: rtfURL)
        let cache = ClipboardPreviewCache()
        let request = ClipboardPreviewRequest(key: "large-preview-v1", richTextURL: rtfURL, imageURLs: [imageURL])
        let coldStart = Date()
        let preview = await cache.load(request)!
        let coldMS = Date().timeIntervalSince(coldStart) * 1000
        precondition(preview.image != nil && preview.lightText != nil && preview.darkText != nil)
        precondition(preview.image!.width <= 960 && preview.image!.height <= 960, "List images must be downsampled")
        precondition(abs(preview.aspectRatio! - 4.0 / 3.0) < 0.001)
        precondition(preview.lightText!.length >= 12000 && preview.lightText!.length < 12032)
        precondition(!preview.lightText!.string.contains("�"), "Text truncation must preserve composed characters")
        let sourceColor = preview.lightText!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        precondition(sourceColor.usingColorSpace(.deviceRGB)!.redComponent > 0.9, "Copied text color must be preserved")
        precondition(preview.lightCanvas!.usingColorSpace(.deviceRGB)!.redComponent > 0.9)

        let count = 20
        let baselineStart = Date()
        for _ in 0..<count {
            let decoded = NSAttributedString(rtf: try Data(contentsOf: rtfURL), documentAttributes: nil)!
            _ = ClipboardTextAppearance.preview(for: decoded)
            let image = NSImage(contentsOf: imageURL)!
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let baselineMS = Date().timeIntervalSince(baselineStart) * 1000
        let warmStart = Date()
        for _ in 0..<count {
            let warm = await cache.load(request)
            precondition(warm === preview, "Warm reads must reuse decoded previews")
        }
        let warmMS = Date().timeIntervalSince(warmStart) * 1000
        try FileManager.default.removeItem(at: imageURL)
        let cachedAfterRemoval = await cache.load(request)
        precondition(cachedAfterRemoval === preview, "Cached rows must not read files again")
        let nextRequest = ClipboardPreviewRequest(key: "large-preview-v2", richTextURL: nil, imageURLs: [imageURL])
        let changed = await cache.load(nextRequest)
        precondition(changed?.image == nil, "A new revision must not reuse an older preview")
        let cancelled = Task { await cache.load(ClipboardPreviewRequest(key: "cancelled", richTextURL: rtfURL, imageURLs: [])) }
        cancelled.cancel()
        let cancellationResult = await cancelled.value
        precondition(cancellationResult == nil, "Offscreen cancelled loads should stop")
        let metrics: [String: Any] = [
            "fixture": "4096x3072 image and long styled RTF", "iterations": count,
            "legacyRepeatedDecodeMS": baselineMS, "coldPreviewMS": coldMS, "warmPreviewMS": warmMS,
            "sourceImageBytes": bitmap.bytesPerRow * bitmap.pixelsHigh,
            "listImageBytes": preview.image!.bytesPerRow * preview.image!.height,
            "scope": "Synthetic decode/cache benchmark; not a scroll frame-rate measurement"
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        print("PASS: downsampling, styles, bounded Unicode text, warm cache, revision changes and cancellation")
    }
}
