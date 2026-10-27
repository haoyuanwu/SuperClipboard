import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A group is a container, with a separate disclosure control and draggable header.
struct TransferFileGroupCard: View {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let item: ClipboardEntry
    let isCopied: Bool
    let onCopy: () -> Void
    @State private var expanded = false

    private var status: EntryAvailability { store.contentAvailability(for: item) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onCopy) {
                    HStack(spacing: 12) {
                        TransferFileIcon(paths: item.filePaths, revision: status, size: 48, isGroup: true)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(item.fileGroupName ?? "文件组").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                Text("\(item.filePaths.count) 项")
                                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(ClipboardTheme.controlFill, in: Capsule())
                                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
                            }
                            Text(item.title).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(ClipboardTheme.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(ClipboardControlStyle())
                .modifier(EntryDragSource(item: item))
                .disabled(status.isMissing)
                .help("单击复制整组，拖动可导出整组文件")
                ToolbarIconButton(symbol: expanded ? "chevron.up" : "chevron.down", title: expanded ? "收起文件组" : "展开文件组") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
                }
                .accessibilityValue(expanded ? "已展开" : "已收起")
            }
            .padding(14)

            if expanded {
                Divider().overlay(ClipboardTheme.border).padding(.horizontal, 14)
                VStack(spacing: 4) {
                    ForEach(item.filePaths, id: \.self) { path in
                        TransferGroupFileRow(group: item, path: path, revision: status)
                    }
                }
                .padding(8)
                .transition(.opacity)
            }

            HStack(spacing: 6) {
                Image(systemName: status.isMissing || status.isPartial ? "exclamationmark.triangle" : (isCopied ? "checkmark" : "square.stack.3d.up"))
                    .accessibilityHidden(true)
                Text(status.isMissing ? "组内文件暂时不可用" : (status.isPartial ? "\(status.missing) 个文件不可用" : (isCopied ? "已复制整组" : "展开可单独复制或拖出")))
                Spacer(minLength: 4)
                Text(item.lastCopiedAt, style: .time).monospacedDigit()
            }
            .font(.system(size: 10))
            .foregroundStyle(isCopied ? ClipboardTheme.successText : ClipboardTheme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(ClipboardTheme.controlFill)
        }
        .foregroundStyle(ClipboardTheme.primary)
        .background(ClipboardTheme.pageBackground.opacity(reduceTransparency ? 1 : 0.70), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ClipboardTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 4)
    }
}

private struct TransferGroupFileRow: View {
    @EnvironmentObject private var store: ClipboardStore
    let group: ClipboardEntry
    let path: String
    let revision: EntryAvailability
    @State private var preview: ClipboardPreview?
    @State private var available = true
    @State private var copied = false
    @State private var copyToken = 0
    private var url: URL { URL(fileURLWithPath: path) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: copy) {
                HStack(spacing: 10) {
                    TransferFileIcon(paths: [path], revision: revision, size: 32, onLoad: { preview = $0 })
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url.lastPathComponent).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text(available ? (url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased()) : "文件暂时不可用")
                            .font(.system(size: 10)).foregroundStyle(ClipboardTheme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7).padding(.leading, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(ClipboardControlStyle())
            .modifier(EntryDragSource(item: group, filePath: path, filePreview: preview?.image))
            .disabled(!available)
            .help("单击复制这个文件，或拖到其他应用")
            ToolbarIconButton(symbol: copied ? "checkmark" : "doc.on.doc", title: copied ? "已复制" : "复制 \(url.lastPathComponent)", size: 28, action: copy)
                .disabled(!available)
        }
        .padding(.trailing, 6)
        .background(ClipboardTheme.utilityFill, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("复制文件", action: copy).disabled(!available)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(!available)
        }
        .task(id: revision) { available = FileManager.default.isReadableFile(atPath: path) }
        .task(id: copyToken) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copied = false
        }
    }

    private func copy() {
        copied = store.copyTransferFile(path, in: group)
        available = FileManager.default.isReadableFile(atPath: path)
        if copied { copyToken += 1 }
    }
}

/// Decode image candidates off the main thread. Non-images keep their native file icon.
struct TransferFileIcon: View {
    let paths: [String]
    var revision = EntryAvailability()
    var size: CGFloat = 48
    var isGroup = false
    var onLoad: ((ClipboardPreview?) -> Void)? = nil
    @State private var preview: ClipboardPreview?

    private var request: ClipboardPreviewRequest {
        let images = isGroup ? [] : paths.filter { UTType(filenameExtension: URL(fileURLWithPath: $0).pathExtension)?.conforms(to: .image) == true }
        return ClipboardPreviewRequest(key: "transfer-icon|\(images)|\(revision.missing)/\(revision.total)", richTextURL: nil,
                                       imageURLs: images.map { URL(fileURLWithPath: $0) })
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if isGroup {
                    Image(systemName: "folder.fill").resizable().scaledToFit().padding(9)
                        .foregroundStyle(ClipboardTheme.toolbarAccent)
                } else if let image = preview?.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else if !isGroup, let path = paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit().padding(3)
                } else {
                    Image(systemName: "folder.fill").resizable().scaledToFit().padding(9)
                        .foregroundStyle(ClipboardTheme.toolbarAccent)
                }
            }
            .frame(width: size, height: size)
            .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))

        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: request) {
            guard !isGroup else { return }
            let result = await ClipboardPreviewCache.shared.load(request)
            guard !Task.isCancelled else { return }
            preview = result
            onLoad?(result)
        }
    }
}

struct TransferFileDragPreview: View {
    let path: String
    var image: CGImage? = nil
    var body: some View {
        HStack(spacing: 10) {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .frame(width: 112, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                TransferFileIcon(paths: [path], size: 56)
            }
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 12, weight: .medium)).lineLimit(2)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .padding(10)
        .foregroundStyle(ClipboardTheme.primary)
        .background(ClipboardTheme.pageBackground, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14))
    }
}
