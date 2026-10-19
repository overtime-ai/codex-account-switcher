import Foundation
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct ClaudeAccountFlowTests {
    @MainActor private final class Desktop: ClaudeDesktopControlling {
        var events: [String] = []
        var onLaunch: ([String]) throws -> Void = { _ in }
        var failsToClose = false
        func close() async throws {
            events.append("close")
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
            #expect(try store.load() == [.existing])
            let data = URL(fileURLWithPath: String(path))
            try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": account, "oauth:tokenCacheV2": "opaque-native-login"]).write(to: data.appending(path: "config.json"))
            try FileManager.default.createDirectory(at: data.appending(path: "claude-code-sessions/\(account)/\(org)"), withIntermediateDirectories: true)
        }
        model.addAccount()
        for _ in 0..<500 where model.isAddingAccount { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!model.isAddingAccount)
        #expect(model.error == nil)
        #expect(try store.load().count == 2)
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
        #expect(try store.load() == [.existing])
        #expect(desktop.events == ["close", "sign-in", "close", "open"])
    }

    @Test func quitFailureStopsBeforeSwitchingOrLaunchingSignIn() async throws {
        let (root, store, desktop, model) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        desktop.failsToClose = true
        await model.open(.existing)
        #expect(desktop.events == ["close"])
        #expect(model.error != nil)
        #expect(try store.load() == [.existing])
        #expect(!model.isOpening)
    }

    @Test func staleAccountMetadataWithoutNativeLoginCannotCompleteRegistration() throws {
        let (root, store, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try store.createPending()
        try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": "11111111-1111-1111-1111-111111111111"]).write(to: store.directory(for: pending).appending(path: "config.json"))
        #expect(try store.signedInProfile(pending) == nil)
        #expect(try store.load() == [.existing])
    }
}
