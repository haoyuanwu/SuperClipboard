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
        Window("SuperClipboard", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(launchAtLogin)
                .task { launchAtLogin.configureDefaultIfNeeded() }
                .preferredColorScheme(appearanceMode.colorScheme)
                .background(AppWindowObserver(role: .main).allowsHitTesting(false))
        }
        .defaultSize(width: 440, height: 640)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuPopoverView()
                .environmentObject(store)
                .environmentObject(launchAtLogin)
                .task { launchAtLogin.configureDefaultIfNeeded() }
                .preferredColorScheme(appearanceMode.colorScheme)
        } label: {
            Image("MenuBarLogo")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .accessibilityLabel("SuperClipboard")
        }
        .menuBarExtraStyle(.window)
    }
}
