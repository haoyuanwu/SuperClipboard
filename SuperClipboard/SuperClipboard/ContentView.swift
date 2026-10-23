//
//  ContentView.swift
//  SuperClipboard
//
//  Created by why on 2026/10/21.
//

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: String, CaseIterable, Identifiable {
    case all = "全部", text = "文字", image = "图片", file = "文件", video = "视频", settings = "设置", about = "关于"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .text: "text.alignleft"
        case .image: "photo"
        case .file: "doc"
        case .video: "play.rectangle"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .all: Color(red: 0.66, green: 0.71, blue: 0.78)
        case .text: Color(red: 0.53, green: 0.73, blue: 0.68)
        case .image: Color(red: 0.72, green: 0.62, blue: 0.77)
        case .file: Color(red: 0.78, green: 0.69, blue: 0.54)
        case .video: Color(red: 0.58, green: 0.68, blue: 0.80)
        case .settings, .about: .secondary
        }
    }

    var lightTint: Color {
        switch self {
        case .all: Color(red: 0.10, green: 0.36, blue: 0.88)
        case .text: Color(red: 0.0, green: 0.46, blue: 0.34)
        case .image: Color(red: 0.56, green: 0.17, blue: 0.76)
        case .file: Color(red: 0.68, green: 0.37, blue: 0.03)
        case .video: Color(red: 0.20, green: 0.29, blue: 0.83)
        case .settings, .about: ClipboardTheme.toolbarAccent
        }
    }
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    @State private var section: LibrarySection = .all
    @State private var showsNotebook = false
    @State private var selectedItem: ClipboardEntry?
    @State private var activePanel: MainPanel?
    @State private var search = ""
    @State private var isSearchExpanded = false
    @State private var historySession = ClipboardListSession()
    @State private var notebookSession = ClipboardListSession()
    @FocusState private var isSearchFocused: Bool

    private var visibleItems: [ClipboardEntry] {
        let current = showsNotebook ? store.notebookEntries : store.entries
        let session = showsNotebook ? notebookSession : historySession
        return session.entries(from: current).filter { item in
            (section == .all || item.kind.rawValue == section.rawValue) &&
            (search.isEmpty || item.searchText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let items = visibleItems
        VStack(spacing: 0) {
            header
                .zIndex(1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ClipboardLayout.cardGap) {
                    if items.isEmpty {
                        ContentUnavailableView(
                            search.isEmpty ? (showsNotebook ? "记事本还是空的" : "暂无剪贴板记录") : "没有匹配的记录",
                            systemImage: showsNotebook ? "book.closed" : "doc.on.clipboard",
                            description: Text(search.isEmpty ? (showsNotebook ? "在历史记录上右键，选择「加入记事本」。" : "复制文字、图片或文件后会自动出现在这里。") : "试试其他搜索词。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ForEach(items) { item in
                            Button { selectedItem = item } label: {
                                HistoryCard(item: item)
                            }
                            .buttonStyle(HistoryCardButtonStyle())
                            .modifier(EntryDragSource(item: item))
                            .help("单击查看，拖到其他应用")
                            .contextMenu { EntryContextMenu(item: item) }
                        }
                    }
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(ClipboardLayout.pageInset)
            }
        }
        .background(ClipboardTheme.pageBackground)
        .foregroundStyle(ClipboardTheme.primary)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 420, maxWidth: 460, minHeight: 440)
        .background {
            AppWindowObserver(role: .main) { visible in
                if visible { refreshSessionOrder() }
            }
            .allowsHitTesting(false)
        }
        .onAppear { refreshSessionOrder() }
        .onChange(of: store.sortOrder) { _, _ in refreshSessionOrder() }
        .onChange(of: store.entries.map(\.id)) { _, _ in
            historySession.includeNewEntries(from: store.entries)
        }
        .onChange(of: store.notebookEntries.map(\.id)) { _, _ in
            notebookSession.includeNewEntries(from: store.notebookEntries)
        }
        .modifier(NotebookErrorAlert(isEnabled: activePanel == nil && selectedItem == nil))
        .modifier(EntryDragErrorAlert())
        .sheet(item: $selectedItem) { item in
            EntryDetail(item: item)
                .frame(width: 420, height: 420)
        }
        .sheet(item: $activePanel) { panel in
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: panel == .settings ? "slider.horizontal.3" : "info.circle")
                            .foregroundStyle(ClipboardTheme.toolbarAccent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(panel == .settings ? "设置" : "关于")
                                .font(.system(size: 15, weight: .semibold))
                            Text(panel == .settings ? "让剪贴板更合你的习惯" : "随手复制，随时取用")
                                .font(.system(size: 11))
                                .foregroundStyle(ClipboardTheme.secondary)
                        }
                    }
                    Spacer()
                    ToolbarIconButton(symbol: "xmark", title: "关闭") { activePanel = nil }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider().overlay(ClipboardTheme.border)
                Group {
                    switch panel {
                    case .settings: settingsView
                    case .about: aboutView
                    }
                }
            }
            .foregroundStyle(ClipboardTheme.primary)
            .background(ClipboardTheme.pageBackground)
            .frame(width: 390, height: 480)
            .modifier(NotebookErrorAlert())
            .onAppear { launchAtLogin.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                launchAtLogin.refresh()
            }
            .onExitCommand { activePanel = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isSearchExpanded {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(ClipboardTheme.toolbarAccent)
                        TextField(text: $search, prompt: Text("搜索记录").foregroundColor(ClipboardTheme.secondary)) { Text("搜索记录") }
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onExitCommand { closeSearch() }
                        Button { closeSearch() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(ClipboardTheme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("收起搜索")
                    }
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 9))
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showsNotebook ? "记事本" : "剪贴板")
                            .font(.system(size: 14, weight: .semibold))
                        Text(showsNotebook ? "独立保存 · \(visibleItems.count) 条" : "最近收集 · \(visibleItems.count) 条")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ClipboardTheme.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    ToolbarIconButton(symbol: "magnifyingglass", title: "展开搜索", size: 30) {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) { isSearchExpanded = true }
                        isSearchFocused = true
                    }
                }
                NotebookToggle(isSelected: showsNotebook, size: 30) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.84)) {
                        showsNotebook.toggle()
                        section = .all
                        search = ""
                    }
                }
                ToolbarIconButton(symbol: "tray.full", title: "悬浮中转", size: 30) {
                    store.transferWindowDidOpen()
                    AppWindowCoordinator.showTransferWindow { openWindow(id: "transfer") }
                }
                Menu {
                    Button("设置…", systemImage: "slider.horizontal.3") { activePanel = .settings }
                    Button("关于 SuperClipboard", systemImage: "info.circle") { activePanel = .about }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ClipboardTheme.toolbarAccent)
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30)
                .help("设置与关于")
                .accessibilityLabel("设置与关于")
            }
            .padding(.leading, 78)
            .padding(.trailing, 12)
            .frame(height: 52)
            .background(WindowDragArea())

            HStack(spacing: 8) {
                categoryBar
                Spacer(minLength: 4)
                Menu {
                    ForEach(ClipboardSortOrder.allCases) { value in
                        Button { store.sortOrder = value } label: {
                            if store.sortOrder == value {
                                Label(value.rawValue, systemImage: "checkmark")
                            } else {
                                Text(value.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClipboardTheme.toolbarAccent)
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 30)
                .accessibilityLabel("排序：\(store.sortOrder.rawValue)")
                .help("排序：\(store.sortOrder.rawValue)")
            }
            .padding(.horizontal, ClipboardLayout.pageInset)
            .frame(height: 42)
            .background(ClipboardTheme.pageBackground.opacity(0.74))
            .overlay(alignment: .bottom) {
                Rectangle().fill(ClipboardTheme.border.opacity(0.7)).frame(height: 1)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ClipboardTheme.primary)
        .background(ClipboardTheme.headerBackground)
    }

    private func refreshSessionOrder() {
        historySession.begin(with: store.sortedEntries)
        notebookSession.begin(with: store.sortedNotebookEntries)
    }

    private var categoryBar: some View {
        HStack(spacing: 3) {
            ForEach([LibrarySection.all, .text, .image, .file, .video]) { value in
                CategoryButton(section: value, isSelected: section == value) {
                    section = value
                }
            }
        }
        .padding(3)
        .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 11))
    }

    private func closeSearch() {
        search = ""
        isSearchFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isSearchExpanded = false }
    }

    private var settingsView: some View {
        Form {
            Section {
                Toggle("开机启动", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.needsApproval {
                    Button("在系统设置中允许开机启动") { launchAtLogin.openLoginItemsSettings() }
                }
                if let message = launchAtLogin.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(ClipboardTheme.dangerText)
                }
            } header: {
                SettingsSectionTitle(title: "通用", symbol: "power")
            }
            Section {
                Picker("显示模式", selection: $appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                SettingsSectionTitle(title: "外观", symbol: "circle.lefthalf.filled")
            }
            Section {
                Picker("最多保留", selection: $store.maxEntries) {
                    Text("100 条").tag(100)
                    Text("500 条").tag(500)
                    Text("1000 条").tag(1000)
                }
                Text("重复内容合并计数，置顶记录不会自动清理。")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.secondary)
                Button("清空未置顶记录", role: .destructive) { store.clearUnpinned() }
                    .foregroundStyle(ClipboardTheme.dangerText)
            } header: {
                SettingsSectionTitle(title: "历史记录", symbol: "clock.arrow.circlepath")
            }
            Section {
                Toggle("拖入内容同时保存到历史记录", isOn: $store.transferDropSavesHistory)
                Text("中转内容独立保存，开启后同时收录到历史记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.secondary)
                HStack(spacing: 6) {
                    Text("关闭后清空")
                    Spacer()
                    TextField("", value: $store.transferClearMinutes, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                        .labelsHidden()
                        .accessibilityLabel("中转站自动清空时间，分钟")
                    Text("分钟").fixedSize().foregroundStyle(ClipboardTheme.secondary)
                    Stepper("自动清空时间", value: $store.transferClearMinutes, in: 1...1440)
                        .labelsHidden()
                }
                Text("支持 1–1440 分钟。重新打开会取消倒计时。")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.secondary)
            } header: {
                SettingsSectionTitle(title: "悬浮中转", symbol: "tray.full")
            }
            Section {
                Button {
                    NSWorkspace.shared.open(store.notebookDirectory)
                } label: {
                    Label {
                        Text(store.notebookDirectory.path)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } icon: { Image(systemName: "folder") }
                }
                .help("在访达中打开记事本目录")
                Button(action: store.chooseNotebookDirectory) {
                    HStack {
                        Text(store.notebookBusy ? "正在保存或迁移…" : "更改保存位置…")
                        if store.notebookBusy { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(store.notebookBusy || store.transferBusy)
                Text("加入时保存独立副本，永久保留；更改位置会迁移已有内容。")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.secondary)
            } header: {
                SettingsSectionTitle(title: "记事本", symbol: "book.closed")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityLabel("SuperClipboard")
            Text("SuperClipboard").font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("把灵感和资料，留在手边。")
                .font(.system(size: 13))
                .foregroundStyle(ClipboardTheme.secondary)
            Text("macOS 剪贴板历史管理 · 版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                .foregroundStyle(ClipboardTheme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("关于")
    }
}

private struct CategoryButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    let section: LibrarySection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var iconTint: Color {
        colorScheme == .dark ? section.tint : section.lightTint
    }

    private var buttonFill: Color {
        if colorScheme == .light {
            return isSelected ? iconTint : iconTint.opacity(isHovered ? 0.18 : 0.09)
        }
        return iconTint.opacity(isHovered ? 0.30 : (isSelected ? 0.20 : 0.07))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14)
                Text(section.rawValue)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
            }
            .foregroundStyle(colorScheme == .light && isSelected ? .white : ClipboardTheme.primary)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(buttonFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isFocused ? ClipboardTheme.focusRing : iconTint.opacity(isHovered ? 0.3 : 0), lineWidth: isFocused ? 2 : 1)
            }
            .scaleEffect(!reduceMotion && isHovered ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "已选择" : "")
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
    }
}

private enum MainPanel: String, Identifiable {
    case settings, about
    var id: String { rawValue }
}

private struct HistoryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ClipboardStore
    let item: ClipboardEntry
    var isTranslucent = false
    @State private var preview: ClipboardPreview?
    @State private var loadedAspectRatio: CGFloat?

    private var accent: Color { AppIconPalette.color(for: item.sourceBundleID) }

    var body: some View {
        let request = store.listPreviewRequest(for: item)
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(ClipboardTheme.cardSecondary.opacity(0.12))
                .frame(height: 0.5)
                .padding(.top, 12)
            HStack(spacing: 8) {
                ClipboardTimestamp(date: item.lastCopiedAt)
                    .layoutPriority(1)
                Text("·")
                Label("\(item.copyCount)", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel("复制 \(item.copyCount) 次")
                if item.isPinned { Image(systemName: "pin.fill") }
                Spacer(minLength: 8)
                SourceAppBadge(item: item)
                    .frame(maxWidth: 120, alignment: .trailing)
                    .layoutPriority(-1)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(ClipboardTheme.cardSecondary)
            .padding(.top, 9)
        }
        .padding(ClipboardLayout.cardPadding)
        .foregroundStyle(ClipboardTheme.cardPrimary)
        .background {
            RoundedRectangle(cornerRadius: ClipboardLayout.cardRadius)
                .fill(
                    LinearGradient(
                        colors: ClipboardCardPalette.gradient(tint: NSColor(accent), isDark: colorScheme == .dark).map { Color(nsColor: $0) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .opacity(isTranslucent ? (colorScheme == .dark ? 0.82 : 0.78) : 1)
                .shadow(color: .black.opacity(isTranslucent ? (colorScheme == .dark ? 0.22 : 0.12) : 0),
                        radius: 12, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ClipboardLayout.cardRadius)
                .strokeBorder(
                    isTranslucent ? Color.white.opacity(colorScheme == .dark ? 0.20 : 0.62) : accent.opacity(0.18),
                    lineWidth: 1
                )
        }
        .task(id: request) {
            let loaded = await store.loadListPreview(for: item, request: request)
            guard !Task.isCancelled else { return }
            preview = loaded
            if let ratio = loaded?.aspectRatio { loadedAspectRatio = ratio }
        }
        .onDisappear { preview = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            if let rich = colorScheme == .dark ? preview?.darkText : preview?.lightText {
                RichTextPreview(attributedText: rich, singleLine: false, heightLimit: 126, usesPreparedColors: true)
                    .frame(maxHeight: 126, alignment: .top)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(nsColor: (colorScheme == .dark ? preview?.darkCanvas : preview?.lightCanvas) ?? .textBackgroundColor)
                            .opacity(isTranslucent ? 0.90 : 1),
                        in: RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius)
                    )
                    .frame(maxHeight: 150, alignment: .top)
                    .clipped()
            } else {
                Text(String((item.plainText ?? "").prefix(12_000)))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(ClipboardTheme.cardPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: 150, alignment: .topLeading)
                    .clipped()
            }
        case .image:
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let image = preview?.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 176)
                            .clipShape(RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius))
                    } else {
                        mediaPlaceholder(symbol: "photo", ratio: 1)
                    }
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.cardSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .video:
            if let image = preview?.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 176)
                    .clipShape(RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius))
            } else if preview == nil {
                mediaPlaceholder(symbol: "play.rectangle", ratio: 16.0 / 9.0)
            } else {
                Text(item.title).font(.system(size: 14))
            }
        case .file:
            HStack(spacing: 12) {
                Image(systemName: item.filePaths.count > 1 ? "folder" : "doc")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 44, height: 48)
                    .background(ClipboardTheme.cardSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                    Text(item.filePaths.count > 1 ? "\(item.filePaths.count) 个文件" : "文件")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipboardTheme.cardSecondary)
                }
            }
        }
    }

    private func mediaPlaceholder(symbol: String, ratio: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius)
            .fill(ClipboardTheme.controlFill)
            .aspectRatio(loadedAspectRatio ?? item.previewAspectRatio ?? ratio, contentMode: .fit)
            .frame(maxHeight: 176)
            .overlay {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(ClipboardTheme.cardSecondary)
            }
    }

}

@MainActor
private enum AppIconPalette {
    private static var cached: [String: Color] = [:]
    private static var icons: [String: NSImage] = [:]
    private static var missingIcons: Set<String> = []
    private static let fallback = Color(red: 0.27, green: 0.30, blue: 0.38)

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !missingIcons.contains(bundleID) else { return nil }
        if let image = icons[bundleID] { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingIcons.insert(bundleID)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    static func color(for bundleID: String?) -> Color {
        guard let bundleID else { return fallback }
        if let cachedColor = cached[bundleID] { return cachedColor }
        var rect = NSRect(x: 0, y: 0, width: 32, height: 32)
        guard let icon = icon(for: bundleID),
              let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            cached[bundleID] = fallback
            return fallback
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        var bestColor: NSColor?
        var bestScore: CGFloat = 0
        for y in stride(from: 2, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 16)) {
            for x in stride(from: 2, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 16)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.55 else { continue }
                let saturation = max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent)
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                let score = saturation * (1 - abs(brightness - 0.5))
                if score > bestScore { bestScore = score; bestColor = color }
            }
        }
        let result = bestColor.map(Color.init(nsColor:)) ?? fallback
        cached[bundleID] = result
        return result
    }
}

private struct SourceAppBadge: View {
    let item: ClipboardEntry

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Text(item.sourceAppName)
                .lineLimit(1)
                .truncationMode(.tail)
            Group {
                if let icon = AppIconPalette.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                }
            }
            .frame(width: 20, height: 20)
        }
        .help(item.sourceAppName)
        .accessibilityElement(children: .combine)
    }
}

struct MenuPopoverView: View {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var copiedItemID: UUID?
    @State private var copyFeedbackToken = 0
    @State private var sessionOrder: [UUID] = []
    @State private var showsNotebook = false
    @State private var confirmsQuit = false

    private var sortedItems: [ClipboardEntry] {
        showsNotebook ? store.sortedNotebookEntries : store.sortedEntries
    }

    private var visibleItems: [ClipboardEntry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: sortedItems.map { ($0.id, $0) })
        let knownIDs = Set(sessionOrder)
        let existing = sessionOrder.compactMap { entriesByID[$0] }
        let added = sortedItems.filter { !knownIDs.contains($0.id) }
        return (existing + added).filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let items = visibleItems
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        PopoverModeButton(title: "历史记录", symbol: "clock.arrow.circlepath", isSelected: !showsNotebook) {
                            selectPopoverMode(notebook: false)
                        }
                        PopoverModeButton(title: "记事本", symbol: "book.closed", isSelected: showsNotebook) {
                            selectPopoverMode(notebook: true)
                        }
                    }
                    .padding(3)
                    .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 11))
                    Spacer(minLength: 0)
                    UtilityGroup {
                        ToolbarIconButton(symbol: "tray.full", title: "悬浮中转", size: 28) {
                            store.transferWindowDidOpen()
                            AppWindowCoordinator.showTransferWindow { openWindow(id: "transfer") }
                        }
                        ToolbarIconButton(symbol: "arrow.up.forward.square", title: "打开主窗口", size: 28) {
                            AppWindowCoordinator.showMainWindow { openWindow(id: "main") }
                        }
                    }
                    ToolbarIconButton(symbol: "power", title: "退出 SuperClipboard", size: 28) {
                        confirmsQuit = true
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClipboardTheme.secondary)
                    TextField(text: $search, prompt: Text(showsNotebook ? "搜索记事本" : "搜索剪贴板").foregroundColor(ClipboardTheme.secondary)) {
                        Text(showsNotebook ? "搜索记事本" : "搜索剪贴板")
                    }
                    .textFieldStyle(.plain)
                    .accessibilityLabel(showsNotebook ? "搜索记事本" : "搜索剪贴板")
                    .onExitCommand { search = "" }
                    if !search.isEmpty {
                        ToolbarIconButton(symbol: "xmark.circle.fill", title: "清空搜索", size: 24) { search = "" }
                    } else {
                        RecordCountBadge(count: items.count)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .frame(height: 36)
                .background(ClipboardTheme.popoverSearchFill, in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11).strokeBorder(ClipboardTheme.border.opacity(0.55), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, ClipboardLayout.pageInset)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .modifier(PopoverHeaderGlassSurface())
            .overlay(alignment: .bottom) {
                Rectangle().fill(ClipboardTheme.border.opacity(0.6)).frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: ClipboardLayout.cardGap) {
                    ForEach(items) { item in
                        Button {
                            if store.copy(item) {
                                copiedItemID = item.id
                                copyFeedbackToken += 1
                            }
                        } label: {
                            PopoverHistoryCard(item: item, isCopied: copiedItemID == item.id)
                        }
                        .buttonStyle(HistoryCardButtonStyle())
                        .modifier(EntryDragSource(item: item))
                        .help("单击复制，拖到其他应用")
                        .contextMenu { EntryContextMenu(item: item) }
                    }
                }
                .padding(ClipboardLayout.pageInset)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? (showsNotebook ? "记事本还是空的" : "暂无剪贴板记录") : "没有匹配的记录",
                        systemImage: search.isEmpty ? (showsNotebook ? "book.closed" : "doc.on.clipboard") : "magnifyingglass",
                        description: Text(search.isEmpty ? (showsNotebook ? "在历史记录上右键，选择「加入记事本」。" : "复制内容后会自动出现在这里。") : "试试其他搜索词。")
                    )
                }
            }
        }
        .allowsHitTesting(!confirmsQuit)
        .accessibilityHidden(confirmsQuit)
        .modifier(PopoverGlassSurface())
        .foregroundStyle(ClipboardTheme.primary)
        .frame(width: 390, height: 520)
        .modifier(NotebookErrorAlert())
        .modifier(EntryDragErrorAlert())
        .overlay {
            if confirmsQuit {
                ZStack {
                    Color.black.opacity(0.16)
                        .contentShape(Rectangle())
                        .onTapGesture { }
                    QuitGlassConfirmation {
                        confirmsQuit = false
                    }
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: confirmsQuit)
        .background {
            AppWindowObserver(role: .popover) { isVisible in
                if isVisible {
                    beginHistorySession()
                } else {
                    copiedItemID = nil
                    confirmsQuit = false
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear { beginHistorySession() }
        .onChange(of: store.sortOrder) { _, _ in
            sessionOrder = sortedItems.map(\.id)
        }
        .task(id: copyFeedbackToken) {
            guard copiedItemID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
                try Task.checkCancellation()
                copiedItemID = nil
            } catch { }
        }
        .onDisappear { copiedItemID = nil; confirmsQuit = false }
    }

    private func beginHistorySession() {
        showsNotebook = false
        search = ""
        copiedItemID = nil
        sessionOrder = store.sortedEntries.map(\.id)
    }

    private func selectPopoverMode(notebook: Bool) {
        guard showsNotebook != notebook else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
            showsNotebook = notebook
        }
        search = ""
        copiedItemID = nil
        sessionOrder = (notebook ? store.sortedNotebookEntries : store.sortedEntries).map(\.id)
    }
}

private struct QuitGlassConfirmation: View {
    let onCancel: () -> Void
    @FocusState private var cancelIsFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "power")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(ClipboardTheme.toolbarAccent)
                .frame(width: 52, height: 52)
                .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 8) {
                Text("退出 SuperClipboard？")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ClipboardTheme.primary)
                Text("退出后将停止记录剪贴板内容。")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.secondary)
            }
            .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("取消")
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 10))
                }
                .focused($cancelIsFocused)
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                    Text("退出")
                        .foregroundStyle(ClipboardTheme.dangerText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .buttonStyle(ClipboardControlStyle())
        }
        .padding(22)
        .frame(width: 310)
        .modifier(PopoverGlassSurface())
        .shadow(color: .black.opacity(0.16), radius: 20, x: 0, y: 10)
        .accessibilityAddTraits(.isModal)
        .onAppear { cancelIsFocused = true }
    }
}

private struct PopoverModeButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? ClipboardTheme.primary : ClipboardTheme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 27)
                .background(isSelected ? ClipboardTheme.selectedSurface : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? ClipboardTheme.border : .clear, lineWidth: 0.5)
                }
        }
        .buttonStyle(ClipboardControlStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PopoverHistoryCard: View {
    let item: ClipboardEntry
    let isCopied: Bool
    var isTranslucent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HistoryCard(item: item, isTranslucent: isTranslucent)
            .overlay(alignment: .topTrailing) {
                if isCopied {
                    Label("已复制", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ClipboardTheme.successText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(ClipboardTheme.successFill, in: Capsule())
                        .padding(9)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isCopied)
    }
}

private struct RichTextPreview: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let attributedText: NSAttributedString
    let singleLine: Bool
    var heightLimit: CGFloat? = nil
    var usesPreparedColors = false

    final class Coordinator {
        struct MeasurementKey: Hashable {
            let width: CGFloat
            let height: CGFloat
        }
        var source: NSAttributedString?
        var isDark = false
        var usesPreparedColors = false
        var resolvedText: NSAttributedString?
        var appliedText: NSAttributedString?
        var measurements: [MeasurementKey: CGSize] = [:]

        func resolve(_ source: NSAttributedString, isDark: Bool, usesPreparedColors: Bool) -> NSAttributedString {
            if self.source === source, self.isDark == isDark,
               self.usesPreparedColors == usesPreparedColors, let resolvedText { return resolvedText }
            self.source = source
            self.isDark = isDark
            self.usesPreparedColors = usesPreparedColors
            let result = usesPreparedColors ? source : ClipboardTextAppearance.preview(for: source, isDark: isDark)
            resolvedText = result
            measurements.removeAll(keepingCapacity: true)
            return result
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let text = context.coordinator.resolve(attributedText, isDark: colorScheme == .dark, usesPreparedColors: usesPreparedColors)
        let view = NSTextField(labelWithAttributedString: text)
        context.coordinator.appliedText = text
        view.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        view.maximumNumberOfLines = singleLine ? 1 : 0
        view.cell?.wraps = !singleLine
        return view
    }
    func updateNSView(_ view: NSTextField, context: Context) {
        let preview = context.coordinator.resolve(attributedText, isDark: colorScheme == .dark, usesPreparedColors: usesPreparedColors)
        if context.coordinator.appliedText !== preview {
            view.attributedStringValue = preview
            context.coordinator.appliedText = preview
        }
        let lineBreakMode: NSLineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        if view.lineBreakMode != lineBreakMode { view.lineBreakMode = lineBreakMode }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let text = context.coordinator.resolve(attributedText, isDark: colorScheme == .dark, usesPreparedColors: usesPreparedColors)
        let limit = singleLine ? 22 : (heightLimit ?? .greatestFiniteMagnitude)
        let key = Coordinator.MeasurementKey(width: width, height: limit)
        if let cached = context.coordinator.measurements[key] { return cached }
        let measured = text.boundingRect(
            with: CGSize(width: width, height: limit),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalHeight = singleLine ? min(22, ceil(measured.height)) : ceil(measured.height)
        let result = CGSize(width: width, height: min(heightLimit ?? naturalHeight, max(20, naturalHeight)))
        if context.coordinator.measurements.count > 8 { context.coordinator.measurements.removeAll(keepingCapacity: true) }
        context.coordinator.measurements[key] = result
        return result
    }
}

private struct EntryContextMenu: View {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.openWindow) private var openWindow
    let item: ClipboardEntry
    var body: some View {
        Button("再次复制", systemImage: "doc.on.doc") { store.copy(item) }
        if !item.isTransferEntry {
            Button(store.isInTransfer(item) ? "在悬浮中转中显示" : "加入悬浮中转", systemImage: "tray.and.arrow.down") {
                store.transferWindowDidOpen()
                store.addToTransfer(item)
                AppWindowCoordinator.showTransferWindow { openWindow(id: "transfer") }
            }
            .disabled(store.transferBusy || store.notebookBusy)
        }
        if !item.isNotebookEntry {
            Button(store.isInNotebook(item) ? "已加入记事本" : "加入记事本", systemImage: "book.closed") {
                store.addToNotebook(item)
            }
            .disabled(store.notebookBusy || store.transferBusy || store.isInNotebook(item))
        }
        if !item.isTransferEntry {
            Button(item.isPinned ? "取消置顶" : "置顶", systemImage: "pin") { store.togglePin(item) }
        }
        if let url = item.firstFileURL {
            Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button(item.isTransferEntry ? "移出中转站" : (item.isNotebookEntry ? "从记事本移除" : "删除记录"), systemImage: "trash", role: .destructive) { store.delete(item) }
            .disabled((item.isNotebookEntry || item.isTransferEntry) && (store.notebookBusy || store.transferBusy))
    }
}

private struct EntryDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    @State private var hasCopied = false
    @State private var copyFailed = false
    let item: ClipboardEntry

    private var accent: Color { AppIconPalette.color(for: item.sourceBundleID) }

    private var currentItem: ClipboardEntry {
        (item.isNotebookEntry ? store.notebookEntries : store.entries).first { $0.id == item.id } ?? item
    }

    var body: some View {
        ZStack {
            ClipboardTheme.pageBackground
            LinearGradient(
                colors: [accent.opacity(0.30), ClipboardTheme.headerBackground, accent.opacity(0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let icon = AppIconPalette.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .opacity(0.10)
                    .blur(radius: 18)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(accent)
                    Text(item.kind == .text ? "文字" : item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    ToolbarIconButton(symbol: "xmark", title: "关闭") { dismiss() }
                }
                .padding(16)
                ScrollView {
                    detailContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        DetailSourceView(item: currentItem)
                            .foregroundStyle(ClipboardTheme.primary)
                        HStack(spacing: 12) {
                            Label {
                                ClipboardTimestamp(date: currentItem.lastCopiedAt)
                            } icon: {
                                Image(systemName: "clock")
                            }
                            Label("\(currentItem.copyCount)", systemImage: "doc.on.doc")
                                .monospacedDigit()
                                .accessibilityLabel("复制 \(currentItem.copyCount) 次")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(ClipboardTheme.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        guard !hasCopied else { return }
                        if store.copy(currentItem) {
                            hasCopied = true
                            copyFailed = false
                        } else {
                            copyFailed = true
                        }
                    } label: {
                        Image(systemName: hasCopied ? "checkmark" : (copyFailed ? "exclamationmark" : "doc.on.doc.fill"))
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(hasCopied ? ClipboardTheme.successText : ClipboardTheme.actionForeground)
                            .background(hasCopied ? ClipboardTheme.successFill : ClipboardTheme.actionFill, in: RoundedRectangle(cornerRadius: ClipboardLayout.controlRadius))
                    }
                    .buttonStyle(ClipboardControlStyle())
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: hasCopied)
                    .accessibilityLabel(hasCopied ? "已复制" : (copyFailed ? "复制失败，请检查原文件后重试" : "再次复制"))
                    .help(hasCopied ? "已复制" : (copyFailed ? "复制失败，请检查原文件后重试" : "再次复制"))
                    .task(id: hasCopied) {
                        guard hasCopied else { return }
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        dismiss()
                    }
                }
                .lineLimit(1)
                .padding(ClipboardLayout.pageInset)
                .overlay(alignment: .top) {
                    Rectangle().fill(ClipboardTheme.border).frame(height: 1)
                }
            }
        }
        .foregroundStyle(ClipboardTheme.primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var detailContent: some View {
        let item = currentItem
        switch item.kind {
        case .text:
            if let rich = store.richText(for: item) {
                RichTextPreview(attributedText: rich, singleLine: false)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .padding(12)
                    .background(Color(nsColor: ClipboardTextAppearance.canvas(for: rich, isDark: colorScheme == .dark)), in: RoundedRectangle(cornerRadius: 9))
            } else {
                Text(item.plainText ?? "")
                    .foregroundStyle(ClipboardTheme.primary)
                    .textSelection(.enabled)
            }
        case .image:
            if let image = store.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Label(item.title, systemImage: item.kind.symbol)
                    .foregroundStyle(ClipboardTheme.secondary)
            }
        case .video:
            if let url = item.firstFileURL, FileManager.default.fileExists(atPath: url.path) {
                VideoDetailPlayer(url: url)
                    .frame(height: 260)
            } else if let image = store.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
            } else {
                Label("视频文件不可用", systemImage: "video.slash")
                    .foregroundStyle(ClipboardTheme.secondary)
            }
        case .file:
            ForEach(item.filePaths, id: \.self) { path in
                VStack(alignment: .leading, spacing: 10) {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc")
                        .foregroundStyle(ClipboardTheme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "folder")
                            Text(path)
                                .font(.system(size: 12, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(ClipboardTheme.secondary)
                        .padding(10)
                        .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                    .accessibilityLabel("在访达中显示：\(path)")
                }
                .padding(.bottom, 12)
            }
        }
    }
}

private struct DetailSourceView: View {
    let item: ClipboardEntry

    var body: some View {
        HStack(spacing: 6) {
            if let icon = AppIconPalette.icon(for: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.fill")
                    .frame(width: 22, height: 22)
            }
            Text(item.sourceAppName)
                .fontWeight(.medium)
                .lineLimit(1)
        }
    }
}

private struct VideoDetailPlayer: View {
    let url: URL
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?

    var body: some View {
        VStack(spacing: 8) {
            VideoSurface(player: player)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 9) {
                Button {
                    if isPlaying { player.pause() } else { player.play() }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "暂停" : "播放")
                Slider(value: $currentTime, in: 0...max(duration, 0.01), onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                    }
                })
                .accessibilityLabel("播放进度")
                Text("\(timeLabel(currentTime)) / \(timeLabel(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ClipboardTheme.secondary)
            }
        }
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            Task {
                let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                duration = seconds.isFinite && seconds > 0 ? seconds : 0
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
                guard !isScrubbing else { return }
                currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if duration > 0 && currentTime >= duration - 0.05 { isPlaying = false }
            }
        }
        .onDisappear {
            player.pause()
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            player.replaceCurrentItem(with: nil)
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct TransferShelfView: View {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var copiedItemID: UUID?
    @State private var copyToken = 0
    @State private var confirmsClear = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(ClipboardTheme.toolbarAccent)
                Text("中转站").font(.system(size: 13, weight: .semibold))
                RecordCountBadge(count: store.transferEntries.count)
                Spacer(minLength: 4)
                if store.transferBusy {
                    ProgressView().controlSize(.small)
                        .help("正在保存中转副本")
                }
                ToolbarIconButton(symbol: "trash", title: "清空中转站", size: 28) { confirmsClear = true }
                    .disabled(store.transferBusy || store.transferEntries.isEmpty)
                ToolbarIconButton(symbol: "xmark", title: "关闭中转站", size: 28) {
                    dismissWindow(id: "transfer")
                }
            }
            .padding(.leading, 78)
            .padding(.trailing, 12)
            .frame(height: 44)
            .background(WindowDragArea())
            .modifier(PopoverHeaderGlassSurface(isTransferShelf: true))

            ScrollView {
                LazyVStack(spacing: ClipboardLayout.cardGap) {
                    ForEach(store.transferEntries) { item in
                        TransferShelfCard(item: item, isCopied: copiedItemID == item.id) {
                            if store.copy(item) {
                                copiedItemID = item.id
                                copyToken += 1
                            }
                        }
                    }
                }
                .padding(ClipboardLayout.pageInset)
            }
            .overlay {
                if store.transferEntries.isEmpty && !store.transferBusy {
                    ContentUnavailableView("中转站还是空的", systemImage: "tray",
                        description: Text("拖入图片、视频、文件或文字，或在记录上右键加入。"))
                }
            }
            HStack(spacing: 6) {
                Label("可拖入 / 拖出", systemImage: "arrow.up.and.down")
                Spacer(minLength: 4)
                Label("关闭后 \(store.transferClearMinutes) 分钟清空", systemImage: "clock")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ClipboardTheme.secondary)
            .padding(.horizontal, ClipboardLayout.pageInset)
            .padding(.vertical, 12)
            .background(ClipboardTheme.shelfChromeFill)
        }
        .foregroundStyle(ClipboardTheme.primary)
        .modifier(TransferShelfGlassSurface())
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 320, idealWidth: 350, maxWidth: 390, minHeight: 360)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(ClipboardTheme.toolbarAccent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(ClipboardTheme.toolbarAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        Label("松开以加入中转站", systemImage: "tray.and.arrow.down.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: TransferShelfDropDelegate.supportedTypes,
                delegate: TransferShelfDropDelegate(isTargeted: $isDropTargeted,
                    canAccept: { !store.transferBusy && !store.notebookBusy }, accept: acceptDrop))
        .background {
            AppWindowObserver(role: .transfer, onVisibilityChange: { visible in
                if visible { store.transferWindowDidOpen() }
            }, onClose: {
                store.transferWindowDidClose()
            })
            .allowsHitTesting(false)
        }
        .modifier(EntryDragErrorAlert())
        .onAppear { store.transferWindowDidOpen() }
        .onDisappear {
            store.transferWindowDidClose()
            copiedItemID = nil
        }
        .confirmationDialog("清空中转站？", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) { store.clearTransfer() }
        } message: {
            Text("仅删除中转副本，历史记录、记事本和源文件会保留。")
        }
        .alert("悬浮中转", isPresented: Binding(
            get: { store.transferError != nil },
            set: { if !$0 { store.transferError = nil } }
        )) {
            Button("好") { store.transferError = nil }
        } message: {
            Text(store.transferError ?? "")
        }
        .task(id: copyToken) {
            guard copiedItemID != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedItemID = nil
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !store.transferBusy, !store.notebookBusy, !providers.isEmpty,
              !ClipboardStore.isTransferDrag(providers) else { return false }
        if providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            let group = DispatchGroup()
            var urls = Array<URL?>(repeating: nil, count: providers.count)
            for (index, provider) in providers.enumerated() {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    switch item {
                    case let value as URL: url = value
                    case let value as Data: url = URL(dataRepresentation: value, relativeTo: nil)
                    case let value as String: url = URL(string: value)
                    default: url = nil
                    }
                    DispatchQueue.main.async {
                        urls[index] = url?.isFileURL == true ? url : nil
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) {
                if urls.allSatisfy({ $0 != nil }) {
                    store.addDroppedFilesToTransfer(urls.compactMap { $0 })
                } else {
                    store.transferError = "无法读取拖入的文件。"
                }
            }
            return true
        }
        guard providers.count == 1 else { return false }
        if let identifier = providers[0].registeredTypeIdentifiers.first(where: {
                  UTType($0)?.conforms(to: .image) == true
              }) {
            let fileExtension = UTType(identifier)?.preferredFilenameExtension ?? "png"
            providers[0].loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                DispatchQueue.main.async {
                    if let data {
                        store.addDroppedImageToTransfer(data, fileExtension: fileExtension)
                    } else {
                        store.transferError = "无法读取拖入的图片。"
                    }
                }
            }
            return true
        }
        guard providers[0].hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return false }
        providers[0].loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let value: String?
            switch item {
            case let text as String: value = text
            case let data as Data: value = String(data: data, encoding: .utf8)
            default: value = nil
            }
            DispatchQueue.main.async {
                if let value, !value.isEmpty {
                    store.addDroppedTextToTransfer(value)
                } else {
                    store.transferError = "无法读取拖入的文字。"
                }
            }
        }
        return true
    }
}

private struct TransferShelfDropDelegate: DropDelegate {
    static let supportedTypes = [UTType.fileURL.identifier, UTType.image.identifier,
                                 UTType.plainText.identifier, ClipboardStore.transferDragTypeIdentifier]
    @Binding var isTargeted: Bool
    let canAccept: () -> Bool
    let accept: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        canAccept() && !info.hasItemsConforming(to: [ClipboardStore.transferDragTypeIdentifier])
    }

    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = validateDrop(info: info)
        isTargeted = allowed
        return DropProposal(operation: allowed ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        return accept(info.itemProviders(for: Self.supportedTypes))
    }
}

private struct TransferShelfCard: View {
    let item: ClipboardEntry
    let isCopied: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            PopoverHistoryCard(item: item, isCopied: isCopied, isTranslucent: true)
        }
        .buttonStyle(HistoryCardButtonStyle())
        .modifier(EntryDragSource(item: item))
        .help("单击复制，拖到其他应用")
        .contextMenu { EntryContextMenu(item: item) }
    }
}

private struct EntryDragSource: ViewModifier {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: ClipboardEntry
    @State private var isDragging = false

    func body(content: Content) -> some View {
        content
            .contentShape(.dragPreview, RoundedRectangle(cornerRadius: ClipboardLayout.cardRadius))
            .scaleEffect(isDragging && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isDragging)
            .onDrag {
                guard let provider = store.entryDragProvider(for: item) else { return NSItemProvider() }
                if #available(macOS 26.0, *) { isDragging = true }
                return provider
            } preview: {
                TransferDragPreview(item: item).environmentObject(store)
            }
            .modifier(TransferDragSessionFeedback(
                onEnd: { _ in isDragging = false },
                onTransferCompleted: { isDragging = false }
            ))
            .onDisappear { isDragging = false }
    }
}

private struct EntryDragErrorAlert: ViewModifier {
    @EnvironmentObject private var store: ClipboardStore

    func body(content: Content) -> some View {
        content.alert("无法拖出内容", isPresented: Binding(
            get: { store.dragError != nil },
            set: { if !$0 { store.dragError = nil } }
        )) {
            Button("好") { store.dragError = nil }
        } message: {
            Text(store.dragError ?? "")
        }
    }
}

private struct TransferDragSessionFeedback: ViewModifier {
    let onEnd: (DropOperation) -> Void
    let onTransferCompleted: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.onDragSessionUpdated { session in
                switch session.phase {
                case .initial, .active: break
                case .ended(let operation): onEnd(operation)
                case .dataTransferCompleted: onTransferCompleted()
                @unknown default: onTransferCompleted()
                }
            }
        } else {
            content
        }
    }
}

private struct TransferDragPreview: View {
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.colorScheme) private var colorScheme
    let item: ClipboardEntry

    var body: some View {
        Group {
            switch item.kind {
            case .text:
                Text(item.plainText ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .frame(width: 208, alignment: .leading)
                    .padding(14)
            case .image:
                if let image = store.thumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 124, height: 96)
                        .padding(6)
                } else {
                    mediaPreview(symbol: "photo", title: item.title)
                }
            case .video:
                if let image = store.thumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 144, height: 90)
                        .clipped()
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .padding(6)
                } else {
                    mediaPreview(symbol: "play.rectangle.fill", title: item.title)
                }
            case .file:
                mediaPreview(symbol: item.filePaths.count > 1 ? "folder.fill" : "doc.fill", title: item.title)
            }
        }
        .foregroundStyle(ClipboardTheme.primary)
        .background(ClipboardTheme.pageBackground, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.22 : 0.72), lineWidth: 1)
        }
    }

    private func mediaPreview(symbol: String, title: String) -> some View {
        HStack(spacing: 10) {
            Group {
                if item.kind == .file, item.filePaths.count == 1, let url = item.firstFileURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(ClipboardTheme.toolbarAccent)
                }
            }
            .frame(width: 38, height: 38)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 190)
        .padding(12)
    }
}
