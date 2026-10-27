//
//  SuperClipboardApp.swift
//  SuperClipboard
//
//  Created by why on 2026/10/21.
//

import SwiftUI

@main
struct SuperClipboardApp: App {
    @StateObject private var store = ClipboardStore()
    @StateObject private var launchAtLogin = LaunchAtLoginManager()
    @AppStorage("appearanceMode") private var appearanceMode: AppAppearanceMode = .light

    var body: some Scene {
        Window("口袋Cube", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(launchAtLogin)
                .task { launchAtLogin.configureDefaultIfNeeded() }
                .modifier(MenuStatusInstaller(store: store, launchAtLogin: launchAtLogin))
                .modifier(TransferShortcutInstaller(store: store))
                .modifier(TransferDragReceiverInstaller(store: store))
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .defaultSize(width: 440, height: 640)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("悬浮中转", id: "transfer") {
            TransferShelfView()
                .environmentObject(store)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .defaultSize(width: 350, height: 520)
        .defaultPosition(.topTrailing)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

    }
}
