import Foundation
import Testing
@testable import CodexAccountSwitcher

struct ClaudeProfilesTests {
    private func fixture() throws -> (URL, ClaudeProfileStore) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ClaudeProfileStore(root: root.appending(path: "profiles"), existingData: root.appending(path: "existing")))
    }

    @Test func savesProfilesWithoutTouchingExistingLoginOrHistory() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: store.existingData, withIntermediateDirectories: true)
        let history = store.existingData.appending(path: "history.json")
        let original = Data("existing history and login placeholder".utf8)
        try original.write(to: history)

        let added = try store.add(name: " Work ")
        #expect(try store.load() == [.existing, added])
        #expect(added.name == "Work")
        #expect(try Data(contentsOf: history) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory(for: added).path).isEmpty)
        #expect(try store.launchArguments(for: .existing).isEmpty)
        #expect(try store.launchArguments(for: added) == ["--user-data-dir=\(store.directory(for: added).path)"])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.directory(for: added).path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test func namesCannotBecomePathsOrLaunchArguments() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try store.add(name: "../quoted ' $(touch unwanted) --flag")
        #expect(store.directory(for: profile).lastPathComponent == profile.id.uuidString)
        #expect(try store.launchArguments(for: profile).count == 1)
        #expect(throws: ClaudeProfileError.self) { try store.add(name: " ") }
        #expect(throws: ClaudeProfileError.self) { try store.add(name: "Existing Claude") }
        #expect(throws: ClaudeProfileError.self) { try store.add(name: String(repeating: "a", count: 81)) }
    }

    @Test func corruptRegistryAndMissingProfilesFailWithoutResettingData() throws {
        let (root, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try store.add(name: "Work")
        try FileManager.default.removeItem(at: store.directory(for: profile))
        #expect(throws: (any Error).self) { try store.launchArguments(for: profile) }
        try FileManager.default.createSymbolicLink(at: store.directory(for: profile), withDestinationURL: root)
        #expect(throws: ClaudeProfileError.self) { try store.launchArguments(for: profile) }
        let registry = store.root.appending(path: "profiles.json")
        let invalid = Data("invalid JSON".utf8)
        try invalid.write(to: registry)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.add(name: "Other") }
        #expect(try Data(contentsOf: registry) == invalid)
    }
}
