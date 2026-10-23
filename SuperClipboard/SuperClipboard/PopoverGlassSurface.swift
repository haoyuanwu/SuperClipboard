import AppKit
import SwiftUI

/// One glass layer for the panel; its scrolling cards retain opaque content
/// surfaces so rich text and image previews keep their contrast.
struct PopoverGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ClipboardTheme.pageBackground)
                } else if #available(macOS 26.0, *) {
                    Color.clear
                        .glassEffect(.regular.tint(colorScheme == .dark ? .black.opacity(0.25) : .white.opacity(0.08)),
                                     in: RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            if colorScheme == .dark {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(ClipboardTheme.pageBackground.opacity(0.48))
                            }
                        }
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            if colorScheme == .dark {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(ClipboardTheme.pageBackground.opacity(0.48))
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.48), ClipboardTheme.border.opacity(0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            }
    }
}

/// A distinct glass strip for compact header controls, with a light-to-clear
/// wash that keeps the title and icons legible over busy content.
struct PopoverHeaderGlassSurface: ViewModifier {
    var isTransferShelf = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    ClipboardTheme.headerBackground
                } else {
                    ZStack {
                        if #available(macOS 26.0, *) {
                            Color.clear
                                .glassEffect(.regular.tint(colorScheme == .dark ? .black.opacity(0.16) : .white.opacity(0.08)),
                                             in: Rectangle())
                        } else {
                            Rectangle().fill(.ultraThinMaterial)
                        }
                        if isTransferShelf {
                            Rectangle().fill(ClipboardTheme.shelfChromeFill)
                        }
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white.opacity(isTransferShelf ? 0.025 : 0.13), .white.opacity(0.015)]
                                : [.white.opacity(isTransferShelf ? 0.24 : 0.46), .white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            }
    }
}

/// The floating shelf has its own translucent shell. A thin adaptive wash
/// bounds contrast while leaving the desktop visible through the glass.
struct TransferShelfGlassSurface: ViewModifier {
    var isFocused = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency || contrast == .increased {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ClipboardTheme.pageBackground)
                } else {
                    ZStack {
                        if isFocused {
                            // Force the native blur to stay active while this window is key.
                            TransferShelfFrostedBackground()
                        } else if #available(macOS 26.0, *) {
                            Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 18))
                        } else {
                            TransferShelfFrostedBackground(material: .underWindowBackground)
                        }
                        RoundedRectangle(cornerRadius: 18)
                            .fill(LinearGradient(
                                colors: colorScheme == .dark
                                    ? [.black.opacity(isFocused ? 0.22 : 0.12), .black.opacity(isFocused ? 0.26 : 0.08)]
                                    : [.white.opacity(isFocused ? 0.20 : 0.10), .white.opacity(isFocused ? 0.16 : 0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [.white.opacity(0.36), .white.opacity(0.08)]
                                : [.white.opacity(0.82), ClipboardTheme.border.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.27 : 0.15), radius: 24, x: 0, y: 12)
    }
}

/// Native behind-window blur with an explicit active state, independent of app focus.
private struct TransferShelfFrostedBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { configure(view) }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
    }
}
