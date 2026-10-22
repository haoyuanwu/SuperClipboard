import AppKit
import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var windowAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum ClipboardTheme {
    static let pageBackground = adaptive(light: (1, 1, 1), dark: (0.12, 0.135, 0.16))
    static let headerBackground = adaptive(light: (0.97, 0.98, 0.99), dark: (0.16, 0.175, 0.20))
    static let primary = adaptive(light: (0.10, 0.12, 0.15), dark: (0.94, 0.95, 0.97))
    static let secondary = adaptive(light: (0.34, 0.37, 0.42), dark: (0.72, 0.75, 0.80))
    static let toolbarAccent = adaptive(light: (0.12, 0.36, 0.88), dark: (0.78, 0.82, 0.90))
    static let cardPrimary = adaptive(light: (0, 0, 0), dark: (0.96, 0.97, 0.99))
    static let cardSecondary = adaptive(light: (0.12, 0.14, 0.17), dark: (0.94, 0.95, 0.97))
    static let controlFill = adaptive(light: (0, 0, 0), dark: (1, 1, 1), alpha: 0.065)
    static let popoverSearchFill = adaptive(light: (1, 1, 1), dark: (0.08, 0.10, 0.14), alpha: 0.88)
    static let popoverHeaderFill = adaptive(light: (1, 1, 1), dark: (0.08, 0.10, 0.14), alpha: 0.78)
    static let border = adaptive(light: (0, 0, 0), dark: (1, 1, 1), alpha: 0.12)
    static let focusRing = adaptive(light: (0.05, 0.28, 0.76), dark: (0.45, 0.72, 1))
    static let hoverBorder = adaptive(light: (0.08, 0.27, 0.61), dark: (0.65, 0.78, 0.98))
    static let actionFill = adaptive(light: (0.12, 0.36, 0.88), dark: (0.45, 0.72, 1))
    static let actionForeground = adaptive(light: (1, 1, 1), dark: (0.05, 0.09, 0.16))
    static let successFill = adaptive(light: (0.88, 0.97, 0.92), dark: (0.12, 0.27, 0.21))
    static let successText = adaptive(light: (0.06, 0.36, 0.22), dark: (0.59, 0.94, 0.73))
    static let dangerText = adaptive(light: (0.68, 0.12, 0.13), dark: (1, 0.58, 0.58))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(deviceRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha)
        })
    }
}
