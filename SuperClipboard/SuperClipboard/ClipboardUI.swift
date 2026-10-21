import SwiftUI

enum ClipboardLayout {
    static let pageInset: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let cardGap: CGFloat = 12
    static let cardRadius: CGFloat = 16
    static let contentRadius: CGFloat = 12
    static let controlSize: CGFloat = 32
    static let controlRadius: CGFloat = 10
    static let interactionDuration: Double = 0.16
}

struct ToolbarIconButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ClipboardTheme.toolbarAccent)
                .frame(width: ClipboardLayout.controlSize, height: ClipboardLayout.controlSize)
        }
        .buttonStyle(ClipboardControlStyle())
        .accessibilityLabel(title)
        .help(title)
    }
}

struct ClipboardControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveSurface(isPressed: configuration.isPressed, radius: ClipboardLayout.controlRadius) {
            configuration.label
        }
    }
}

struct HistoryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveSurface(isPressed: configuration.isPressed, radius: ClipboardLayout.cardRadius, isCard: true) {
            configuration.label
        }
    }
}

private struct InteractiveSurface<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false
    let isPressed: Bool
    let radius: CGFloat
    var isCard = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background {
                if !isCard && (isHovered || isPressed) {
                    RoundedRectangle(cornerRadius: radius).fill(ClipboardTheme.controlFill)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(isFocused ? ClipboardTheme.focusRing : (isCard && isHovered ? ClipboardTheme.hoverBorder : .clear), lineWidth: isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .scaleEffect(reduceMotion || !isPressed ? 1 : 0.985)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: ClipboardLayout.interactionDuration), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: ClipboardLayout.interactionDuration), value: isPressed)
    }
}
