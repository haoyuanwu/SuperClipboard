import AppKit
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var errorMessage: String?

    private let service: SMAppService
    private let defaults: UserDefaults
    private let preferenceKey = "launchAtLoginRequested"

    init(service: SMAppService = .mainApp, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        refresh()
    }

    func configureDefaultIfNeeded() {
        // Register once; subsequent launches respect changes made in System Settings.
        guard defaults.object(forKey: preferenceKey) == nil else { return }
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            defaults.set(enabled, forKey: preferenceKey)
        } catch {
            errorMessage = "无法更改开机启动：\(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        let status = service.status
        isEnabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
