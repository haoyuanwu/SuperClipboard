import AppKit

enum ClipboardCardPalette {
    static func gradient(tint: NSColor, isDark: Bool = false) -> [NSColor] {
        if isDark {
            let top = NSColor(deviceRed: 0.22, green: 0.24, blue: 0.28, alpha: 1)
            let bottom = NSColor(deviceRed: 0.19, green: 0.21, blue: 0.26, alpha: 1)
            return [top.blended(withFraction: 0.14, of: tint) ?? top,
                    bottom.blended(withFraction: 0.10, of: tint) ?? bottom]
        }
        let top = NSColor(deviceRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
        let bottom = NSColor(deviceRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)
        return [top.blended(withFraction: 0.42, of: tint) ?? top,
                bottom.blended(withFraction: 0.24, of: tint) ?? bottom]
    }
}

nonisolated enum ClipboardTextAppearance {
    static let documentBackgroundKey = NSAttributedString.Key("SuperClipboard.documentBackground")
    private static let darkCanvas = NSColor(calibratedRed: 0.15, green: 0.165, blue: 0.20, alpha: 1)
    private static let lightCanvas = NSColor(deviceRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)

    static func canvas(for text: NSAttributedString, isDark: Bool = false) -> NSColor {
        let defaultCanvas = isDark ? darkCanvas : lightCanvas
        guard text.length > 0 else { return defaultCanvas }
        if let background = text.attribute(documentBackgroundKey, at: 0, effectiveRange: nil) as? NSColor,
           background.alphaComponent > 0.5 {
            return background
        }
        if let background = text.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
           background.alphaComponent > 0.5 {
            return background
        }
        let foreground = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        guard !isAutomatic(foreground), let foreground else { return defaultCanvas }
        // Rich text often includes text colors but omits the source document's canvas.
        // Dark source text needs a white canvas; unstyled text still uses the card's light canvas.
        return luminance(foreground) < 0.3 ? .white : darkCanvas
    }

    static func preview(for text: NSAttributedString, isDark: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let canvas = canvas(for: text, isDark: isDark)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard isAutomatic(attributes[.foregroundColor] as? NSColor) else { return }
            let background = (attributes[.backgroundColor] as? NSColor) ?? canvas
            let effectiveBackground = composite(background, over: canvas)
            let dark = NSColor.black
            let lightContrast = (luminance(.white) + 0.05) / (luminance(effectiveBackground) + 0.05)
            let darkContrast = (luminance(effectiveBackground) + 0.05) / (luminance(dark) + 0.05)
            let fallback = lightContrast >= darkContrast ? NSColor.white : dark
            result.addAttribute(.foregroundColor, value: fallback, range: range)
        }
        return result
    }

    private static func composite(_ foreground: NSColor, over background: NSColor) -> NSColor {
        guard let front = foreground.usingColorSpace(.deviceRGB),
              let back = background.usingColorSpace(.deviceRGB) else { return background }
        let alpha = front.alphaComponent
        return NSColor(deviceRed: front.redComponent * alpha + back.redComponent * (1 - alpha),
                       green: front.greenComponent * alpha + back.greenComponent * (1 - alpha),
                       blue: front.blueComponent * alpha + back.blueComponent * (1 - alpha), alpha: 1)
    }

    private static func isAutomatic(_ color: NSColor?) -> Bool {
        guard let color else { return true }
        return color == .textColor || color == .labelColor || color == .controlTextColor
    }

    private static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}
