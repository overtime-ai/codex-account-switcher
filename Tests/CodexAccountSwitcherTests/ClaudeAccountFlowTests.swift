import Foundation
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct ClaudeAccountFlowTests {
    @MainActor private final class Desktop: ClaudeDesktopControlling {
        var events: [String] = []
        var onLaunch: ([String]) throws -> Void = { _ in }
        var failsToClose = false
        var closedProcesses: [pid_t?] = []
        func close(processIdentifier: pid_t?) async throws {
            events.append("close")
            closedProcesses.append(processIdentifier)
            if failsToClose { throw ClaudeProfileError.quitFailed }
        }
        func launch(arguments: [String]) async throws {
            events.append(arguments.contains("claude://code") ? "sign-in" : "open")
            try onLaunch(arguments)
        }
    }

    private func fixture() throws -> (URL, ClaudeProfileStore, Desktop, ClaudeProfilesModel) {
        let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
        let store = ClaudeProfileStore(root: root.appending(path: "profiles"), existingData: root.appending(path: "existing"))
        let desktop = Desktop()
        return (root, store, desktop, ClaudeProfilesModel(store: store, desktop: desktop))
    }

    @Test func addAccountSavesOnlyAfterNativeLoginAndCodeInitialization() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = "11111111-1111-1111-1111-111111111111"
        let org = "22222222-2222-2222-2222-222222222222"
        desktop.onLaunch = { arguments in
            guard arguments.contains("claude://code"), let path = arguments.first?.split(separator: "=", maxSplits: 1).last else { return }
            #expect(try store.load().isEmpty)
            let data = URL(fileURLWithPath: String(path))
            try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account, "oauth:tokenCacheV2": "opaque-native-login"]).write(to: data.appending(path: "config.json"))
            try FileManager.default.createDirectory(at: data.appending(path: "claude-code-sessions/\(account)/\(org)"), withIntermediateDirectories: true)
        }
        model.addAccount()
        for _ in 0..<500 where model.isAddingAccount { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!model.isAddingAccount)
        #expect(model.error == nil)
        #expect(try store.load().count == 1)
        #expect(try store.lastOpened().id == model.profiles.last?.id)
        #expect(desktop.events == ["close", "sign-in", "close", "open"])
    }

    @Test func cancellationRestoresPreviousAccountWithoutSavingAnIncompleteLogin() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.addAccount()
        for _ in 0..<500 where !desktop.events.contains("sign-in") { try await Task.sleep(for: .milliseconds(1)) }
        model.cancelAddingAccount()
        for _ in 0..<500 where model.isAddingAccount { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!model.isAddingAccount)
        #expect(model.error == nil)
        #expect(try store.load().isEmpty)
        #expect(desktop.events == ["close", "sign-in", "close", "open"])
    }

    @Test func quitFailureStopsBeforeSwitchingOrLaunchingSignIn() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.existing)
        desktop.failsToClose = true
        await model.open(.existing)
        #expect(desktop.events == ["close"])
        #expect(model.error != nil)
        #expect(try store.load() == [.existing])
        #expect(!model.isOpening)
    }

    @Test func unregisteredDefaultCannotBeSelectedOrAutomaticallyAdded() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.load()
        await model.open(.existing)
        #expect(model.profiles.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(desktop.events.isEmpty)
        #expect(model.error != nil)
    }

    @Test func staleAccountMetadataWithoutNativeLoginCannotCompleteRegistration() throws {
        let (root, store, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try store.createPending()
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "11111111-1111-1111-1111-111111111111"]).write(to: store.directory(for: pending).appending(path: "config.json"))
        #expect(try store.signedInProfile(pending) == nil)
        #expect(try store.load().isEmpty)
    }

    private func saveSelectedAccount(_ store: ClaudeProfileStore) throws -> ClaudeProfile {
        let profile = try store.add(name: "Selected")
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "11111111-1111-1111-1111-111111111111"])
            .write(to: store.directory(for: profile).appending(path: "config.json"))
        try store.recordOpened(profile)
        return profile
    }

    @Test func defaultRelaunchRestoresSelectedAccountWithoutSynchronizingOrChangingFiles() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try saveSelectedAccount(store)
        // Deliberately invalid history: recovery must not invoke the synchronizer at all.
        let history = store.root.appending(path: "history-state.json")
        let original = Data("untouched history".utf8)
        try original.write(to: history)
        let registry = try Data(contentsOf: store.root.appending(path: "profiles.json"))
        let config = try Data(contentsOf: store.directory(for: selected).appending(path: "config.json"))
        desktop.onLaunch = { arguments in
            #expect(arguments == ["--user-data-dir=\(store.directory(for: selected).path)"])
        }
        await model.restoreDefaultLaunch(processIdentifier: 123, usesDefaultProfile: { _ in true })
        #expect(desktop.events == ["close", "open"])
        #expect(desktop.closedProcesses == [123])
        #expect(model.error == nil)
        #expect(!model.isOpening)
        #expect(try store.lastOpened() == selected)
        #expect(try Data(contentsOf: history) == original)
        #expect(try Data(contentsOf: store.root.appending(path: "profiles.json")) == registry)
        #expect(try Data(contentsOf: store.directory(for: selected).appending(path: "config.json")) == config)
    }

    @Test func explicitProfileLaunchOrUnknownProcessIsLeftAlone() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveSelectedAccount(store)
        await model.restoreDefaultLaunch(processIdentifier: 123, usesDefaultProfile: { _ in false })
        #expect(desktop.events.isEmpty)
        #expect(model.error == nil)
    }

    @Test func defaultLaunchWithoutSelectedAccountIsLeftAlone() async throws {
        let (root, _, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.restoreDefaultLaunch(processIdentifier: 123, usesDefaultProfile: { _ in true })
        #expect(desktop.events.isEmpty)
        #expect(model.error == nil)
    }

    @Test func defaultRelaunchDoesNotProceedIfQuitFailsOrProfileIsMissing() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try saveSelectedAccount(store)
        desktop.failsToClose = true
        await model.restoreDefaultLaunch(processIdentifier: 123, usesDefaultProfile: { _ in true })
        #expect(desktop.events == ["close"])
        #expect(model.error != nil)
        #expect(try store.lastOpened() == selected)
        desktop.events = []
        try FileManager.default.removeItem(at: store.directory(for: selected))
        await model.restoreDefaultLaunch(processIdentifier: 123, usesDefaultProfile: { _ in true })
        #expect(desktop.events.isEmpty)
        #expect(model.error != nil)
    }

    @Test func addingAccountIsNotInterruptedByLaunchRecovery() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try saveSelectedAccount(store)
        model.load()
        model.addAccount()
        await model.restoreDefaultLaunch(processIdentifier: 123, usesDefaultProfile: { _ in
            Issue.record("Account registration must not trigger launch recovery")
            return true
        })
        model.cancelAddingAccount()
        for _ in 0..<500 where model.isAddingAccount { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!desktop.closedProcesses.contains(123))
    }

    @Test func accountSwitchTransfersPinsWithoutAccessibilityOrAccountDetails() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(.existing)
        let target = try store.add(name: "Target")
        let org = "33333333-3333-3333-3333-333333333333"
        for (profile, account) in [(ClaudeProfile.existing, "11111111-1111-1111-1111-111111111111"),
                                    (target, "22222222-2222-2222-2222-222222222222")] {
            let directory = store.directory(for: profile)
            let code = directory.appending(path: "claude-code-sessions/\(account)/\(org)")
            try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account])
                .write(to: directory.appending(path: "config.json"))
            if profile == .existing {
                let id = "local_44444444-4444-4444-4444-444444444444"
                try JSONSerialization.data(withJSONObject: ["sessionId": id,
                    "cliSessionId": "55555555-5555-5555-5555-555555555555", "cwd": "/repo", "lastActivityAt": 1,
                    "title": "Keep my thread", "isStarred": true, "error": "You've hit your session limit"])
                    .write(to: code.appending(path: "\(id).json"))
            }
        }
        model.load()
        await model.open(target)
        #expect(desktop.events == ["close", "open"])
        #expect(try store.lastOpened() == target)
        #expect(!model.isOpening)
        #expect(model.error == nil)
    }
}
