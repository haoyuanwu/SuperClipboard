import AppKit
import ImageIO

struct ClipboardPreviewRequest: Hashable, Sendable {
    let key: String
    let richTextURL: URL?
    let imageURLs: [URL]
}

/// Immutable data is decoded on one worker actor, keeping fast scrolling from
/// launching an unbounded number of image decoders or RTF imports.
nonisolated final class ClipboardPreview: @unchecked Sendable {
    let image: CGImage?
    let aspectRatio: CGFloat?
    let lightText: NSAttributedString?
    let darkText: NSAttributedString?
    let lightCanvas: NSColor?
    let darkCanvas: NSColor?

    init(image: CGImage? = nil, aspectRatio: CGFloat? = nil, text: NSAttributedString? = nil) {
        self.image = image
        self.aspectRatio = aspectRatio
        lightText = text.map { ClipboardTextAppearance.preview(for: $0, isDark: false) }
        darkText = text.map { ClipboardTextAppearance.preview(for: $0, isDark: true) }
        lightCanvas = text.map { ClipboardTextAppearance.canvas(for: $0, isDark: false) }
        darkCanvas = text.map { ClipboardTextAppearance.canvas(for: $0, isDark: true) }
    }

    var memoryCost: Int {
        (image.map { $0.bytesPerRow * $0.height } ?? 0) + (lightText?.length ?? 0) * 32 + 256
    }
}

actor ClipboardPreviewCache {
    static let shared = ClipboardPreviewCache()
    private let cache: NSCache<NSString, ClipboardPreview> = {
        let cache = NSCache<NSString, ClipboardPreview>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        cache.countLimit = 180
        return cache
    }()

    func load(_ request: ClipboardPreviewRequest) -> ClipboardPreview? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: request.key as NSString) { return cached }
        var text: NSAttributedString?
        if let url = request.richTextURL, let data = try? Data(contentsOf: url), !Task.isCancelled {
            var attributes: NSDictionary?
            if let decoded = NSAttributedString(rtf: data, documentAttributes: &attributes) {
                // Only the top 150 pt is visible in a card. Bound text storage
                // without changing the full RTF used by detail and copy actions.
                let length = min(decoded.length, 12_000)
                let range = (decoded.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length))
                let limited = NSMutableAttributedString(attributedString: decoded.attributedSubstring(from: range))
                if let background = (attributes?[NSAttributedString.DocumentAttributeKey.backgroundColor]
                    ?? attributes?[NSAttributedString.DocumentAttributeKey.backgroundColor.rawValue]) as? NSColor {
                    limited.addAttribute(ClipboardTextAppearance.documentBackgroundKey, value: background,
                                         range: NSRange(location: 0, length: limited.length))
                }
                text = limited
            }
        }
        guard !Task.isCancelled else { return nil }
        var image: CGImage?
        var ratio: CGFloat?
        for url in request.imageURLs {
            guard !Task.isCancelled else { return nil }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { continue }
            ratio = ClipboardPreviewImage.aspectRatio(source: source)
            // Keep Retina card widths sharp while bounding very tall screenshots.
            let maxPixels = min(4_096, max(960, 960 / max(ratio ?? 1, 0.01)))
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
            if image != nil { break }
        }
        guard !Task.isCancelled else { return nil }
        let preview = ClipboardPreview(image: image, aspectRatio: ratio, text: text)
        cache.setObject(preview, forKey: request.key as NSString, cost: preview.memoryCost)
        return preview
    }
}

nonisolated enum ClipboardPreviewImage {
    static func aspectRatio(data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return aspectRatio(source: source)
    }

    static func aspectRatio(source: CGImageSource) -> CGFloat? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        return (5...8).contains(orientation) ? height / width : width / height
    }
}
