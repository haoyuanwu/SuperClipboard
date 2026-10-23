import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A drag pasteboard may retain its old file URLs after a session finishes.
/// Only a new pasteboard generation belonging to the current mouse gesture qualifies.
struct TransferDragHintPolicy {
    private(set) var initialChangeCount = 0
    private(set) var consumed = false

    mutating func begin(changeCount: Int) {
        initialChangeCount = changeCount
        consumed = false
    }

    mutating func consume() { consumed = true }

    func shouldShow(buttonDown: Bool, changeCount: Int, hasFiles: Bool, isTransfer: Bool, canAccept: Bool) -> Bool {
        buttonDown && !consumed && changeCount != initialChangeCount && hasFiles && !isTransfer && canAccept
    }

    static func frame(in visibleFrame: NSRect, size: NSSize = NSSize(width: 232, height: 88)) -> NSRect {
        NSRect(x: visibleFrame.maxX - size.width - 16, y: visibleFrame.maxY - size.height - 16,
               width: size.width, height: size.height)
    }
}

@MainActor
final class TransferDragReceiver {
    static let shared = TransferDragReceiver()
    private weak var store: ClipboardStore?
    private var open: (() -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var releaseTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var destination: TransferDragDestination?
    private var policy = TransferDragHintPolicy()
    private let pasteboard = NSPasteboard(name: .drag)

    func configure(store: ClipboardStore, open: @escaping () -> Void) {
        self.store = store
        self.open = open
        guard globalMonitor == nil && localMonitor == nil else { return }
        policy.begin(changeCount: pasteboard.changeCount)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event.type)
            return event
        }
    }

    private var canAccept: Bool {
        guard let store else { return false }
        return importTask == nil && !store.transferBusy && !store.transferDropLoading && !store.notebookBusy
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            finishGesture()
            policy.begin(changeCount: pasteboard.changeCount)
        case .leftMouseDragged:
            releaseTask?.cancel()
            releaseTask = nil
            if timer == nil {
                let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                self.timer = timer
                // Drag tracking uses a different run loop mode from ordinary app events.
                RunLoop.main.add(timer, forMode: .common)
            }
            refresh()
        case .leftMouseUp:
            finishAfterRelease()
        default: break
        }
    }

    private func refresh() {
        let down = (NSEvent.pressedMouseButtons & 1) != 0
        guard down else { finishAfterRelease(); return }
        let isTransfer = pasteboard.types?.contains(NSPasteboard.PasteboardType(ClipboardStore.transferDragTypeIdentifier)) == true
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        guard policy.shouldShow(buttonDown: down, changeCount: pasteboard.changeCount, hasFiles: hasFiles,
                                isTransfer: isTransfer, canAccept: canAccept) else {
            panel?.orderOut(nil)
            return
        }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return }
        let frame = TransferDragHintPolicy.frame(in: screen.visibleFrame)
        let panel = makePanel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func finishAfterRelease() {
        guard releaseTask == nil else { return }
        // Let the destination receive performDragOperation before removing its window.
        releaseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self else { return }
            self.releaseTask = nil
            if (NSEvent.pressedMouseButtons & 1) == 0 { self.finishGesture() }
        }
    }

    private func finishGesture() {
        timer?.invalidate()
        timer = nil
        releaseTask?.cancel()
        releaseTask = nil
        panel?.orderOut(nil)
        destination?.highlighted = false
        policy.consume()
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let frame = NSRect(x: 0, y: 0, width: 232, height: 88)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let destination = TransferDragDestination(frame: NSRect(origin: .zero, size: frame.size))
        destination.canAccept = { [weak self] in self?.canAccept == true }
        destination.accept = { [weak self] urls in self?.accept(urls) == true }
        panel.contentView = destination
        self.panel = panel
        self.destination = destination
        return panel
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard canAccept, let store, !urls.isEmpty else { return false }
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }
        guard store.acceptTransferFileDrop(providers) else { return false }
        finishGesture()
        importTask = Task { [weak self] in
            while store.transferDropLoading || store.transferBusy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard let self else { return }
            self.importTask = nil
            // Open on failure too, so the existing shelf error alert is visible.
            store.transferWindowDidOpen()
            if let open = self.open { AppWindowCoordinator.showTransferWindow(open: open) }
        }
        return true
    }
}

private final class TransferDragDestination: NSView {
    var canAccept: (() -> Bool)?
    var accept: (([URL]) -> Bool)?
    var highlighted = false {
        didSet {
            guard highlighted != oldValue else { return }
            hosting.rootView = TransferDragHintView(highlighted: highlighted)
        }
    }
    private let hosting = NSHostingView(rootView: TransferDragHintView(highlighted: false))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        return canAccept?() == true
            && board.types?.contains(NSPasteboard.PasteboardType(ClipboardStore.transferDragTypeIdentifier)) != true
            && board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = accepts(sender)
        return highlighted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender), let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        highlighted = false
        return accept?(urls) == true
    }
}

private struct TransferDragHintView: View {
    let highlighted: Bool
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ClipboardTheme.toolbarAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(highlighted ? "松开加入中转站" : "拖进来加入中转站").font(.system(size: 13, weight: .semibold))
                Text("支持多个文件一起拖入").font(.system(size: 11)).foregroundStyle(ClipboardTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ClipboardTheme.primary)
        .modifier(TransferShelfGlassSurface())
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(highlighted ? ClipboardTheme.focusRing : ClipboardTheme.border, lineWidth: highlighted ? 2 : 1))
        .preferredColorScheme(appearanceMode.colorScheme)
    }
}

struct TransferDragReceiverInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let store: ClipboardStore
    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            TransferDragReceiver.shared.configure(store: store) { action(id: "transfer") }
        }
    }
}
