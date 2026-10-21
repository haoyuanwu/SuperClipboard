//
//  ContentView.swift
//  SuperClipboard
//
//  Created by why on 2026/10/21.
//

import AppKit
import AVKit
import SwiftUI

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
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    @State private var section: LibrarySection = .all
    @State private var selectedItem: ClipboardEntry?
    @State private var activePanel: MainPanel?
    @State private var search = ""
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFocused: Bool

    private var visibleItems: [ClipboardEntry] {
        store.sortedEntries.filter { item in
            (section == .all || item.kind.rawValue == section.rawValue) &&
            (search.isEmpty || item.searchText.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: ClipboardLayout.cardGap) {
                    if visibleItems.isEmpty {
                        ContentUnavailableView(
                            search.isEmpty ? "暂无剪贴板记录" : "没有匹配的记录",
                            systemImage: "doc.on.clipboard",
                            description: Text(search.isEmpty ? "复制文字、图片或文件后会自动出现在这里。" : "试试其他搜索词。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVStack(spacing: ClipboardLayout.cardGap) {
                            ForEach(visibleItems) { item in
                                Button { selectedItem = item } label: {
                                    HistoryCard(item: item)
                                }
                                .buttonStyle(HistoryCardButtonStyle())
                                .contextMenu { EntryContextMenu(item: item) }
                            }
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
        .sheet(item: $selectedItem) { item in
            EntryDetail(item: item)
                .frame(width: 420, height: 420)
        }
        .sheet(item: $activePanel) { panel in
            VStack(spacing: 0) {
                HStack {
                    Text(panel == .settings ? "设置" : "关于")
                        .font(.headline)
                    Spacer()
                    Button { activePanel = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(ClipboardTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                Divider()
                Group {
                    switch panel {
                    case .settings: settingsView
                    case .about: aboutView
                    }
                }
            }
            .foregroundStyle(ClipboardTheme.primary)
            .background(ClipboardTheme.pageBackground)
            .frame(width: 390, height: 440)
            .onAppear { launchAtLogin.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                launchAtLogin.refresh()
            }
            .onExitCommand { activePanel = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            if isSearchExpanded {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ClipboardTheme.toolbarAccent)
                    TextField(text: $search, prompt: Text("搜索记录").foregroundColor(ClipboardTheme.secondary.opacity(0.8))) { Text("搜索记录") }
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
                .frame(height: 28)
                .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                ToolbarIconButton(symbol: "magnifyingglass", title: "展开搜索") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isSearchExpanded = true }
                    isSearchFocused = true
                }
            }
            if !isSearchExpanded {
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
                        .foregroundStyle(ClipboardTheme.toolbarAccent)
                        .frame(width: ClipboardLayout.controlSize, height: ClipboardLayout.controlSize)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: ClipboardLayout.controlSize, height: ClipboardLayout.controlSize)
                .accessibilityLabel("排序：\(store.sortOrder.rawValue)")
                .help("排序：\(store.sortOrder.rawValue)")
                categoryBar
                Spacer(minLength: 4)
            }
            HStack(spacing: 0) {
                ToolbarIconButton(symbol: "gearshape", title: "设置") { activePanel = .settings }
                ToolbarIconButton(symbol: "info.circle", title: "关于") { activePanel = .about }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(ClipboardTheme.primary)
        .padding(.leading, 78)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(WindowDragArea())
        .background(ClipboardTheme.headerBackground)
    }

    private var categoryBar: some View {
        HStack(spacing: 2) {
            ForEach([LibrarySection.all, .text, .image, .file, .video]) { value in
                CategoryButton(section: value, isSelected: section == value) {
                    section = value
                }
            }
        }
        .padding(2)
        .background(ClipboardTheme.controlFill, in: Capsule())
    }

    private func closeSearch() {
        search = ""
        isSearchFocused = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isSearchExpanded = false }
    }

    private var settingsView: some View {
        Form {
            Section("通用") {
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
            }
            Section("外观") {
                Picker("显示模式", selection: $appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section("历史记录") {
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
            Text("SuperClipboard").font(.largeTitle.bold())
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
    @State private var showsName = false

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
            Image(systemName: section.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colorScheme == .light && isSelected ? .white : iconTint.opacity(colorScheme == .light || isSelected || isHovered ? 1 : 0.82))
                .brightness(colorScheme == .dark && isHovered ? 0.08 : 0)
                .shadow(color: iconTint.opacity(isHovered ? 0.14 : 0), radius: 3)
                .frame(width: 28, height: 28)
                .background(buttonFill, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(iconTint.opacity(isHovered ? 0.4 : 0), lineWidth: 1)
                }
                .overlay {
                    if isFocused {
                        Capsule().stroke(ClipboardTheme.focusRing, lineWidth: 2)
                            .padding(-2)
                    }
                }
                .scaleEffect(!reduceMotion && isHovered ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(isSelected ? "已选择" : "")
        .onHover { hovering in
            isHovered = hovering
            if !hovering { showsName = false }
        }
        .task(id: isHovered) {
            guard isHovered else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                showsName = true
            } catch { }
        }
        .overlay(alignment: .top) {
            if showsName {
                Text(section.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClipboardTheme.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(ClipboardTheme.headerBackground, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(ClipboardTheme.border, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    .fixedSize()
                    .offset(y: 36)
                    .transition(.opacity.combined(with: .offset(y: -3)))
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isSelected)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsName)
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

    private var accent: Color { AppIconPalette.color(for: item.sourceBundleID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.top, 12)
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
        }
        .overlay {
            RoundedRectangle(cornerRadius: ClipboardLayout.cardRadius).strokeBorder(accent.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            if let rich = store.richText(for: item) {
                RichTextPreview(attributedText: rich, singleLine: false, heightLimit: 126)
                    .frame(maxHeight: 126, alignment: .top)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: ClipboardTextAppearance.canvas(for: rich, isDark: colorScheme == .dark)), in: RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius))
                    .frame(maxHeight: 150, alignment: .top)
                    .clipped()
            } else {
                Text(item.plainText ?? "")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(ClipboardTheme.cardPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: 150, alignment: .topLeading)
                    .clipped()
            }
        case .image:
            VStack(alignment: .leading, spacing: 8) {
                if let image = store.thumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius))
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .foregroundStyle(ClipboardTheme.cardSecondary)
                }
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(ClipboardTheme.cardSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .video:
            if let image = store.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: ClipboardLayout.contentRadius))
            } else {
                Text(item.title).font(.system(size: 14))
            }
        case .file:
            Label(item.title, systemImage: "doc")
                .font(.system(size: 14))
                .lineLimit(3)
        }
    }

}

@MainActor
private enum AppIconPalette {
    private static var cached: [String: Color] = [:]
    private static let fallback = Color(red: 0.27, green: 0.30, blue: 0.38)

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func color(for bundleID: String?) -> Color {
        guard let bundleID else { return fallback }
        if let cachedColor = cached[bundleID] { return cachedColor }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let data = NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return fallback }

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
                if let id = item.sourceBundleID,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
    @State private var search = ""
    @State private var copiedItemID: UUID?
    @State private var copyFeedbackToken = 0
    @State private var sessionOrder: [UUID] = []

    private var visibleItems: [ClipboardEntry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0) })
        let knownIDs = Set(sessionOrder)
        let existing = sessionOrder.compactMap { entriesByID[$0] }
        let added = store.sortedEntries.filter { !knownIDs.contains($0.id) }
        return (existing + added).filter { search.isEmpty || $0.searchText.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(ClipboardTheme.secondary)
                    TextField(text: $search, prompt: Text("搜索记录").foregroundColor(ClipboardTheme.secondary.opacity(0.8))) { Text("搜索记录") }
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索记录")
                        .onExitCommand { search = "" }
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ClipboardTheme.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清空搜索")
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: ClipboardLayout.controlRadius))

                ToolbarIconButton(symbol: "arrow.up.forward.square", title: "打开主窗口") {
                    AppWindowCoordinator.showMainWindow { openWindow(id: "main") }
                }
            }
            .padding(.horizontal, ClipboardLayout.pageInset)
            .padding(.vertical, 10)
            .background(ClipboardTheme.headerBackground)

            ScrollView {
                LazyVStack(spacing: ClipboardLayout.cardGap) {
                    ForEach(visibleItems) { item in
                        Button {
                            store.copy(item)
                            copiedItemID = item.id
                            copyFeedbackToken += 1
                        } label: {
                            PopoverHistoryCard(item: item, isCopied: copiedItemID == item.id)
                        }
                        .buttonStyle(HistoryCardButtonStyle())
                        .help("单击复制")
                        .contextMenu { EntryContextMenu(item: item) }
                    }
                }
                .padding(ClipboardLayout.pageInset)
            }
            .overlay {
                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        search.isEmpty ? "暂无剪贴板记录" : "没有匹配的记录",
                        systemImage: search.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                        description: Text(search.isEmpty ? "复制内容后会自动出现在这里。" : "试试其他搜索词。")
                    )
                }
            }
        }
        .background(ClipboardTheme.pageBackground)
        .foregroundStyle(ClipboardTheme.primary)
        .frame(width: 390, height: 520)
        .background {
            AppWindowObserver(role: .popover) { isVisible in
                if isVisible {
                    sessionOrder = store.sortedEntries.map(\.id)
                } else {
                    copiedItemID = nil
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear { sessionOrder = store.sortedEntries.map(\.id) }
        .onChange(of: store.sortOrder) { _, _ in
            sessionOrder = store.sortedEntries.map(\.id)
        }
        .task(id: copyFeedbackToken) {
            guard copiedItemID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
                try Task.checkCancellation()
                copiedItemID = nil
            } catch { }
        }
        .onDisappear { copiedItemID = nil }
    }
}

private struct PopoverHistoryCard: View {
    let item: ClipboardEntry
    let isCopied: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HistoryCard(item: item)
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

    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(labelWithAttributedString: ClipboardTextAppearance.preview(for: attributedText, isDark: colorScheme == .dark))
        view.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        view.maximumNumberOfLines = singleLine ? 1 : 0
        view.cell?.wraps = !singleLine
        return view
    }
    func updateNSView(_ view: NSTextField, context: Context) {
        let preview = ClipboardTextAppearance.preview(for: attributedText, isDark: colorScheme == .dark)
        if !view.attributedStringValue.isEqual(to: preview) {
            view.attributedStringValue = preview
        }
        let lineBreakMode: NSLineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        if view.lineBreakMode != lineBreakMode { view.lineBreakMode = lineBreakMode }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let measured = attributedText.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalHeight = singleLine ? min(22, ceil(measured.height)) : ceil(measured.height)
        return CGSize(width: width, height: min(heightLimit ?? naturalHeight, max(20, naturalHeight)))
    }
}

private struct EntryContextMenu: View {
    @EnvironmentObject private var store: ClipboardStore
    let item: ClipboardEntry
    var body: some View {
        Button("再次复制", systemImage: "doc.on.doc") { store.copy(item) }
        Button(item.isPinned ? "取消置顶" : "置顶", systemImage: "pin") { store.togglePin(item) }
        if let url = item.firstFileURL {
            Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button("删除记录", systemImage: "trash", role: .destructive) { store.delete(item) }
    }
}

private struct EntryDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss
    let item: ClipboardEntry

    private var accent: Color { AppIconPalette.color(for: item.sourceBundleID) }

    private var currentItem: ClipboardEntry {
        store.entries.first { $0.id == item.id } ?? item
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
                    Button { store.copy(item) } label: {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(ClipboardTheme.actionForeground)
                            .background(ClipboardTheme.actionFill, in: RoundedRectangle(cornerRadius: ClipboardLayout.controlRadius))
                    }
                    .buttonStyle(ClipboardControlStyle())
                    .accessibilityLabel("再次复制")
                    .help("再次复制")
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
