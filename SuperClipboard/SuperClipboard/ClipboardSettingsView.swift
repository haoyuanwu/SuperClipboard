import AppKit
import SwiftUI

/// A compact, native settings form. Each section owns its controls and nearby feedback.
struct ClipboardSettingsView: View {
    @EnvironmentObject private var store: ClipboardStore
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginManager
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light
    @State private var confirmsClear = false
    @State private var checking = false
    @State private var checkCompleted = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin.isEnabled }, set: launchAtLogin.setEnabled)) {
                    SettingsCopy("开机启动", detail: "登录 Mac 后，自动准备好剪贴板。")
                }
                .toggleStyle(.switch)
                .accessibilityLabel("开机启动")
                .accessibilityHint("登录 Mac 后自动启动应用")
                if launchAtLogin.needsApproval {
                    Button("前往系统设置允许启动", action: launchAtLogin.openLoginItemsSettings)
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.callout).foregroundStyle(ClipboardTheme.dangerText)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("显示模式").font(.system(size: 13, weight: .medium))
                    HStack(spacing: 8) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            appearanceOption(mode)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                SettingsHeading("通用与外观", symbol: "slider.horizontal.3", detail: "按你的习惯开始每一天")
            }

            Section {
                TransferShortcutSettings()
            } header: {
                SettingsHeading("快捷键", symbol: "keyboard", detail: "在任何软件中，快速唤出中转站")
            }

            Section {
                Toggle(isOn: $store.transferDropSavesHistory) {
                    SettingsCopy("拖入内容保存到历史记录", detail: "默认仅留在中转站，开启后同时收录。")
                }
                .toggleStyle(.switch)
                .accessibilityLabel("拖入内容保存到历史记录")
                HStack(spacing: 8) {
                    SettingsCopy("关闭后自动清空", detail: "重新打开中转站会取消倒计时。")
                    Spacer(minLength: 8)
                    TextField("分钟", value: $store.transferClearMinutes, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .accessibilityLabel("中转站自动清空时间，1 至 1440 分钟")
                    Text("分钟").foregroundStyle(ClipboardTheme.secondary).fixedSize()
                    Stepper("自动清空时间", value: $store.transferClearMinutes, in: 1...1440).labelsHidden()
                }
            } header: {
                SettingsHeading("悬浮中转", symbol: "tray.full", detail: "临时收集，随手拖出")
            } footer: {
                Text("清空时间支持 1–1440 分钟，中转内容会保存独立副本。")
            }

            Section {
                Picker(selection: $store.maxEntries) {
                    Text("100 条").tag(100)
                    Text("500 条").tag(500)
                    Text("1000 条").tag(1000)
                } label: {
                    SettingsCopy("保留数量", detail: "重复内容合并，置顶记录始终保留。")
                }
                .accessibilityLabel("历史记录保留数量")
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        UnavailableRecordsBar(scope: .history)
                        HStack {
                            SettingsCopy("内容可用性", detail: checking ? "正在检查文件与原始内容…" : (checkCompleted ? "检查完成，列表状态已更新。" : "检查被移动、删除或无法访问的内容。"))
                            Spacer(minLength: 8)
                            if checking { ProgressView().controlSize(.small) }
                            Button("检查") {
                                checking = true
                                Task {
                                    await store.refreshAvailability()
                                    checking = false
                                    checkCompleted = true
                                }
                            }.disabled(checking)
                        }
                        Divider()
                        HStack {
                            SettingsCopy("清空未置顶记录", detail: "移除历史记录，保留置顶和记事本。")
                            Spacer(minLength: 8)
                            Button("清空…", role: .destructive) { confirmsClear = true }
                                .foregroundStyle(ClipboardTheme.dangerText)
                                .disabled(store.notebookBusy || store.transferBusy || store.transferDropLoading)
                        }
                    }
                    .padding(.vertical, 8)
                } label: {
                    Label("记录维护", systemImage: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(ClipboardTheme.secondary)
                }
            } header: {
                SettingsHeading("历史记录", symbol: "clock.arrow.circlepath", detail: "管理保存数量与失效内容")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCopy("保存位置", detail: "独立副本永久保留，更改位置会迁移已有内容。")
                    Button { NSWorkspace.shared.open(store.notebookDirectory) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder").foregroundStyle(ClipboardTheme.toolbarAccent)
                            Text(store.notebookDirectory.path)
                                .font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ClipboardTheme.secondary)
                        }
                        .padding(12)
                        .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(ClipboardControlStyle())
                    .help("在访达中打开记事本目录")
                    HStack {
                        if store.notebookBusy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(store.notebookBusy ? "正在保存或迁移…" : "更改保存位置…", action: store.chooseNotebookDirectory)
                            .disabled(store.notebookBusy || store.transferBusy)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                SettingsHeading("记事本", symbol: "book.closed", detail: "为值得留下的内容，找个固定位置")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(ClipboardTheme.headerBackground)
        .font(.system(size: 13))
        .controlSize(.regular)
        .confirmationDialog("清空所有未置顶的历史记录？", isPresented: $confirmsClear) {
            Button("清空未置顶记录", role: .destructive) { store.clearUnpinned() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这项操作无法撤销。置顶记录、记事本和中转站内容会保留。")
        }
    }

    private func appearanceOption(_ mode: AppAppearanceMode) -> some View {
        let selected = appearanceMode == mode
        let symbol = mode == .system ? "circle.lefthalf.filled" : (mode == .light ? "sun.max" : "moon")
        return Button { appearanceMode = mode } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular)).accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(mode.title).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)) }
                }
            }
            .foregroundStyle(selected ? ClipboardTheme.focusRing : ClipboardTheme.secondary)
            .frame(maxWidth: .infinity).frame(height: 72)
            .background(selected ? ClipboardTheme.selectedSurface : ClipboardTheme.utilityFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? ClipboardTheme.focusRing : ClipboardTheme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(ClipboardControlStyle())
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsCopy: View {
    let title: String
    let detail: String
    init(_ title: String, detail: String) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(ClipboardTheme.primary)
            Text(detail).font(.system(size: 11)).foregroundStyle(ClipboardTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
}

private struct SettingsHeading: View {
    let title: String
    let symbol: String
    let detail: String
    init(_ title: String, symbol: String, detail: String) { self.title = title; self.symbol = symbol; self.detail = detail }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(ClipboardTheme.toolbarAccent)
                .frame(width: 28, height: 28)
                .background(ClipboardTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ClipboardTheme.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(ClipboardTheme.secondary)
            }
        }.padding(.vertical, 6)
    }
}
