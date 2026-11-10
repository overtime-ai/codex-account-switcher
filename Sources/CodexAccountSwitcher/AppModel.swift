import SwitcherCore
import AppKit
import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    init(status: SMAppService.Status) {
        switch status {
        case .notRegistered:
            self = .disabled
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .unavailable
        @unknown default:
            self = .unavailable
        }
    }

    var isOn: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
final class AppModel: AccountController, @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    @Published private(set) var launchAtLoginState: LaunchAtLoginState = .disabled

    private var codexQuitObserver: NSObjectProtocol?

    override init(store: AccountStore, codex: any AccountClient, switchService: any SwitchServicing) {
        super.init(store: store, codex: codex, switchService: switchService)
        onChange = { [weak self] in self?.objectWillChange.send() }
        refreshLaunchAtLoginStatus()
        keepCodexDesktopStateShared(store: store)
    }

    /// Codex Desktop recreates its account-scoped state key on every launch, and the next launch then
    /// skips SSH auto-connect. Clear it whenever Desktop is not running so every launch loads the shared
    /// state, however Desktop is started (Dock, login item, update relaunch or a switch).
    private func keepCodexDesktopStateShared(store: AccountStore) {
        codexQuitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == "com.openai.codex" else { return }
            MainActor.assumeIsolated { self?.clearCodexDesktopStateKey(store: store) }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
            clearCodexDesktopStateKey(store: store)
        }
    }

    private func clearCodexDesktopStateKey(store: AccountStore) {
        Task {
            do { try await store.shareDesktopState() } catch {
                visibleError = OperationError(stage: nil, titleKey: "operation_failed", messageKey: nil,
                                              message: error.localizedDescription, underlyingDescription: nil)
            }
        }
    }

    static func live() -> AppModel {
        let store = AccountStore()
        let codex = CodexClient()
        return AppModel(store: store, codex: codex,
                        switchService: SwitchService(desktop: DesktopController(), store: store, codex: codex))
    }

    var launchesAtLogin: Bool { launchAtLoginState.isOn }
    var launchAtLoginRequiresApproval: Bool { launchAtLoginState == .requiresApproval }
    var launchAtLoginUnavailable: Bool { launchAtLoginState == .unavailable }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginState = LaunchAtLoginState(status: SMAppService.mainApp.status)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            visibleError = OperationError(stage: nil, titleKey: "operation_failed", messageKey: nil,
                                          message: error.localizedDescription, underlyingDescription: nil)
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
