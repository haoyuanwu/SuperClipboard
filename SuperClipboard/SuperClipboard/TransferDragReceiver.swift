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

/// Browsers offer image bytes or an image URL rather than a local file URL.
enum TransferWebImageDrop {
    static let imageTypes = [UTType.png, .tiff, .jpeg, .gif, .heic, .webP]
    static var registeredTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .rtf, NSPasteboard.PasteboardType("com.trolltech.anymime.text--uri-list")] + imageTypes.map { NSPasteboard.PasteboardType($0.identifier) }
    }

    static func fileURLs(in board: NSPasteboard) -> [URL] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return urls }
        let type = NSPasteboard.PasteboardType("com.trolltech.anymime.text--uri-list")
        return (board.string(forType: type) ?? "").components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.hasPrefix("#"), let url = URL(string: value), url.isFileURL else { return nil }
            return url
        }
    }

    static func imageURL(in board: NSPasteboard) -> URL? {
        guard let raw = board.string(forType: .URL), let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return url
    }

    static func textContent(in board: NSPasteboard) -> (String, Data?)? {
        if let data = board.data(forType: .rtf), let text = NSAttributedString(rtf: data, documentAttributes: nil), !text.string.isEmpty {
            return (text.string, data)
        }
        for type in [NSPasteboard.PasteboardType.URL, .string] {
            if let value = board.string(forType: type), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (value, nil)
            }
        }
        return nil
    }

    static func hasSupportedContent(_ board: NSPasteboard) -> Bool {
        !fileURLs(in: board).isEmpty
            || imageTypes.contains { board.types?.contains(NSPasteboard.PasteboardType($0.identifier)) == true }
            || imageURL(in: board) != nil
            || board.types?.contains(where: { [.string, .URL, .rtf].contains($0) }) == true
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
    private var mouseWasDown = false
    private var idlePasteboardCount = 0
    private var releaseTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var panel: NSPanel?
    private var destination: TransferDragDestination?
    private var policy = TransferDragHintPolicy()
    private let pasteboard = NSPasteboard(name: .drag)
    var isHintVisible: Bool { panel?.isVisible == true }
    var isMonitoring: Bool { timer != nil && localMonitor != nil }

    func configure(store: ClipboardStore, open: @escaping () -> Void) {
        self.store = store
        self.open = open
        guard globalMonitor == nil && localMonitor == nil else { return }
        idlePasteboardCount = pasteboard.changeCount
        policy.begin(changeCount: idlePasteboardCount)
        let poller = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = poller
        RunLoop.main.add(poller, forMode: .common)
        // Register the native destination/window before the first drag begins.
        // Creating the window during tracking can miss the initial enter/drop.
        _ = makePanel().windowNumber
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
        return importTask == nil && !store.transferDragIsInternal && !store.transferBusy && !store.transferDropLoading && !store.notebookBusy
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            store?.beginExternalDragGesture()
            finishGesture()
            mouseWasDown = true
            policy.begin(changeCount: idlePasteboardCount)
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
        if !down {
            mouseWasDown = false
            idlePasteboardCount = pasteboard.changeCount
            if panel?.isVisible == true { finishAfterRelease() }
            return
        }
        if !mouseWasDown {
            mouseWasDown = true
            policy.begin(changeCount: idlePasteboardCount)
        }
        // Once AppKit has entered the destination, let its session own completion.
        // Pasteboard mutation or a late monitor event must not remove the target.
        if destination?.isTracking == true { return }
        let isTransfer = pasteboard.types?.contains(NSPasteboard.PasteboardType(ClipboardStore.transferDragTypeIdentifier)) == true
        let hasFiles = TransferWebImageDrop.hasSupportedContent(pasteboard)
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
            if (NSEvent.pressedMouseButtons & 1) == 0 {
                if self.destination?.isTracking == true {
                    // Native prepare/perform can arrive after the monitor's mouse-up.
                    // draggingEnded will dismiss cancelled or rejected sessions.
                    return
                }
                self.finishGesture()
            }
        }
    }

    private func finishGesture() {
        releaseTask?.cancel()
        releaseTask = nil
        panel?.orderOut(nil)
        destination?.resetTracking()
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
        destination.acceptImage = { [weak self] data, ext in self?.acceptImage(data: data, fileExtension: ext) == true }
        destination.acceptImageURL = { [weak self] url in self?.acceptImage(data: nil, fileExtension: url.pathExtension, remoteURL: url) == true }
        destination.acceptText = { [weak self] text, rtf in self?.acceptText(text, rtf: rtf) == true }
        destination.onSessionEnded = { [weak self] in self?.finishGesture() }
        panel.contentView = destination
        panel.registerForDraggedTypes(TransferWebImageDrop.registeredTypes)
        self.panel = panel
        self.destination = destination
        return panel
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard canAccept, let store, !urls.isEmpty else { return false }
        guard store.acceptTransferURLs(urls) else { return false }
        finishGesture()
        importTask = Task { [weak self] in
            while store.transferDropLoading || store.transferBusy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard let self else { return }
            self.importTask = nil
            guard !store.transferDropCancelled else { return }
            // Open on failure too, so the existing shelf error alert is visible.
            store.transferWindowDidOpen()
            if let open = self.open { AppWindowCoordinator.showTransferWindow(open: open) }
        }
        return true
    }
    private func acceptText(_ text: String, rtf: Data?) -> Bool {
        guard canAccept, let store else { return false }
        finishGesture()
        store.addDroppedTextToTransfer(text, rtfData: rtf)
        importTask = Task { [weak self] in
            defer { self?.importTask = nil }
            while store.transferBusy {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            store.transferWindowDidOpen()
            if let open = self?.open { AppWindowCoordinator.showTransferWindow(open: open) }
        }
        return true
    }

    private func acceptImage(data: Data?, fileExtension: String, remoteURL: URL? = nil) -> Bool {
        guard canAccept, let store else { return false }
        finishGesture()
        importTask = Task { [weak self] in
            defer { self?.importTask = nil }
            do {
                let bytes: Data
                if let data { bytes = data }
                else if let remoteURL {
                    var request = URLRequest(url: remoteURL)
                    request.timeoutInterval = 30
                    let (download, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    bytes = download
                } else { return }
                guard bytes.count <= 50 * 1024 * 1024, NSImage(data: bytes) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                store.addDroppedImageToTransfer(bytes, fileExtension: fileExtension, isWebImage: true)
                while store.transferBusy {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                store.transferError = "无法读取网页图片，请尝试将图片下载后拖入：\(error.localizedDescription)"
            }
            store.transferWindowDidOpen()
            if let open = self?.open { AppWindowCoordinator.showTransferWindow(open: open) }
        }
        return true
    }

}

final class TransferDragDestination: NSView {
    var canAccept: (() -> Bool)?
    var accept: (([URL]) -> Bool)?
    var acceptImage: ((Data, String) -> Bool)?
    var acceptImageURL: ((URL) -> Bool)?
    var acceptText: ((String, Data?) -> Bool)?
    var onSessionEnded: (() -> Void)?
    private(set) var isTracking = false
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
        registerForDraggedTypes(TransferWebImageDrop.registeredTypes)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The SwiftUI hosting view is decorative. Route the complete rectangle to
    // this registered native destination, including the label and empty space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    func accepts(_ board: NSPasteboard) -> Bool {
        canAccept?() == true
            && board.types?.contains(NSPasteboard.PasteboardType(ClipboardStore.transferDragTypeIdentifier)) != true
            && TransferWebImageDrop.hasSupportedContent(board)
    }

    func beginTracking(_ board: NSPasteboard) -> NSDragOperation {
        isTracking = accepts(board)
        highlighted = isTracking
        return isTracking ? .copy : []
    }

    func resetTracking() {
        isTracking = false
        highlighted = false
    }

    func performDrop(_ board: NSPasteboard) -> Bool {
        guard accepts(board) else { resetTracking(); return false }
        resetTracking()
        let urls = TransferWebImageDrop.fileURLs(in: board)
        if !urls.isEmpty { return accept?(urls) == true }
        // Consume promised image bytes while the drag pasteboard is still valid.
        for type in TransferWebImageDrop.imageTypes {
            if let data = board.data(forType: NSPasteboard.PasteboardType(type.identifier)), NSImage(data: data) != nil {
                return acceptImage?(data, type.preferredFilenameExtension ?? "png") == true
            }
        }
        if let url = TransferWebImageDrop.imageURL(in: board) { return acceptImageURL?(url) == true }
        if let (text, rtf) = TransferWebImageDrop.textContent(in: board) { return acceptText?(text, rtf) == true }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        beginTracking(sender.draggingPasteboard)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { resetTracking() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender.draggingPasteboard) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { performDrop(sender.draggingPasteboard) }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        resetTracking()
        onSessionEnded?()
    }

}

private struct TransferDragHintView: View {
    let highlighted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ClipboardTheme.toolbarAccent)
                .frame(width: 40, height: 40)
                .background(ClipboardTheme.controlFill.opacity(highlighted ? 1 : 0), in: RoundedRectangle(cornerRadius: 12))
                .scaleEffect(highlighted && !reduceMotion ? 1.08 : 1)
                .offset(y: highlighted && !reduceMotion ? 2 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(highlighted ? "松开加入中转站" : "拖进来加入中转站")
                    .font(.system(size: 13, weight: .semibold))
                Text(highlighted ? "已准备好接收内容" : "文件、图片、文字和链接")
                    .font(.system(size: 11)).foregroundStyle(ClipboardTheme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(ClipboardTheme.primary)
        .modifier(TransferShelfGlassSurface(showsBorder: false))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .fill(ClipboardTheme.toolbarAccent.opacity(highlighted ? 0.12 : 0))
                .allowsHitTesting(false)
        }
        // Animate within a constant native drop rectangle so entering does not
        // move the hit target or generate spurious exit/enter callbacks.
        .scaleEffect(reduceMotion ? 1 : (highlighted ? 1 : 0.97))
        .padding(3)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: highlighted)
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
