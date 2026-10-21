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
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isCompressed = false
    let isPressed: Bool
    let radius: CGFloat
    var isCard = false
    @ViewBuilder let content: () -> Content

    private var isElevated: Bool { isCard && isHovered && isEnabled }
    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        if isCard { return isCompressed ? 0.972 : (isElevated ? 1.006 : 1) }
        return isPressed ? 0.985 : 1
    }

    var body: some View {
        ZStack {
            content()
                .background {
                    if !isCard && (isHovered || isPressed) {
                        RoundedRectangle(cornerRadius: radius).fill(ClipboardTheme.controlFill)
                    }
                }
                .overlay {
                    if isCard && isElevated {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(colorScheme == .dark ? 0.32 : 0.65), .white.opacity(0.03)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(isFocused ? ClipboardTheme.focusRing : .clear, lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(isElevated ? (colorScheme == .dark ? 0.22 : 0.10) : 0), radius: isCompressed ? 3 : 9, x: 0, y: isCompressed ? 1 : 5)
                .scaleEffect(scale)
                .offset(y: reduceMotion || !isElevated || isCompressed ? 0 : -2)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isHovered)
                .animation(reduceMotion ? nil : (isCompressed ? .easeOut(duration: 0.09) : .spring(response: 0.32, dampingFraction: 0.62)), value: isCompressed)
                .animation(reduceMotion ? nil : .easeOut(duration: ClipboardLayout.interactionDuration), value: isPressed)
        }
        // Keep the pointer target stationary while the visible card floats.
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .onHover { isHovered = $0 }
        .task(id: isPressed) {
            guard isCard else { return }
            if isPressed {
                isCompressed = true
            } else {
                // Brief clicks still get a visible press before the spring release.
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
                isCompressed = false
            }
        }
    }
}

struct NotebookToggle: View {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        ToolbarIconButton(symbol: isSelected ? "book.closed.fill" : "book.closed",
                          title: isSelected ? "返回剪贴板历史" : "记事本", action: action)
            .background(isSelected ? ClipboardTheme.controlFill : .clear,
                        in: RoundedRectangle(cornerRadius: ClipboardLayout.controlRadius))
            .overlay(alignment: .topTrailing) {
                if store.notebookBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityValue(isSelected ? "记事本，已选择" : "剪贴板历史")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
    }
}

struct NotebookErrorAlert: ViewModifier {
    @EnvironmentObject private var store: ClipboardStore
    var isEnabled = true

    func body(content: Content) -> some View {
        content.alert("记事本", isPresented: Binding(
            get: { isEnabled && store.notebookError != nil },
            set: { if !$0 { store.notebookError = nil } }
        )) {
            Button("好") { store.notebookError = nil }
        } message: {
            Text(store.notebookError ?? "")
        }
    }
}
