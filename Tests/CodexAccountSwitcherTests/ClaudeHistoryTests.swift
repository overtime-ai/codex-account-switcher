import Foundation
import Testing
@testable import CodexAccountSwitcher

struct ClaudeHistoryTests {
    private struct Fixture {
        let root: URL
        let store: ClaudeProfileStore
        let work: ClaudeProfile
        let account = "11111111-1111-1111-1111-111111111111"
        let otherAccount = "22222222-2222-2222-2222-222222222222"
        let org = "33333333-3333-3333-3333-333333333333"
        let session = "local_44444444-4444-4444-4444-444444444444"
        let project = "55555555-5555-5555-5555-555555555555"

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
            store = ClaudeProfileStore(root: root.appending(path: "switcher"), existingData: root.appending(path: "existing"))
            work = try store.add(name: "Work")
            try write(["lastKnownAccountUuid": account], to: store.existingData.appending(path: "config.json"))
            try write(["lastKnownAccountUuid": otherAccount], to: store.directory(for: work).appending(path: "config.json"))
            for (profile, id) in [(ClaudeProfile.existing, account), (work, otherAccount)] {
                try FileManager.default.createDirectory(at: store.directory(for: profile).appending(path: "claude-code-sessions/\(id)/\(org)"), withIntermediateDirectories: true)
            }
        }

        func code(_ profile: ClaudeProfile) -> URL {
            store.directory(for: profile).appending(path: "claude-code-sessions/\(profile == .existing ? account : otherAccount)/\(org)/\(session).json")
        }
        func spaces(_ profile: ClaudeProfile) -> URL {
            store.directory(for: profile).appending(path: "local-agent-mode-sessions/\(profile == .existing ? account : otherAccount)/\(org)/spaces.json")
        }
        func writeSession(_ profile: ClaudeProfile, activity: Int = 1) throws {
            try write(["sessionId": session, "cliSessionId": "66666666-6666-6666-6666-666666666666",
                       "cwd": "/project", "originCwd": "/project", "lastActivityAt": activity,
                       "title": "Keep my chat", "spaceId": project, "unknownFutureField": "preserve",
                       "permissionMode": "bypassPermissions", "remoteMcpServersConfig": ["private-server"],
                       "userSelectedProjectUuids": ["cloud-project"]], to: code(profile))
        }
        func write(_ object: [String: Any], to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
        }
        func read(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    }

    @Test func sharesLocalChatsAndProjectsWithoutSharingLoginOrCloudReferences() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        try f.write(["rootMetadata": true, "spaces": [["id": f.project, "name": "My project", "updatedAt": 1,
                                                      "folders": [["path": "/project"]], "instructions": "Keep instructions",
                                                      "projects": [["uuid": "cloud-id"]], "migration": ["cloud": true]]]], to: f.spaces(.existing))
        let original = try Data(contentsOf: f.code(.existing))
        let login = try Data(contentsOf: f.store.directory(for: f.work).appending(path: "config.json"))
        let history = ClaudeHistory(store: f.store)
        #expect(try history.synchronize(to: f.work) == 2)
        let chat = try f.read(f.code(f.work))
        #expect(chat["title"] as? String == "Keep my chat")
        #expect(chat["cwd"] as? String == "/project")
        #expect(chat["unknownFutureField"] as? String == "preserve")
        #expect(chat["permissionMode"] as? String == "default")
        #expect(chat["remoteMcpServersConfig"] == nil)
        #expect(chat["userSelectedProjectUuids"] == nil)
        let projects = try f.read(f.spaces(f.work))["spaces"] as! [[String: Any]]
        #expect(projects.first?["name"] as? String == "My project")
        #expect(projects.first?["instructions"] as? String == "Keep instructions")
        #expect(projects.first?["projects"] == nil)
        #expect(projects.first?["migration"] == nil)
        #expect(try Data(contentsOf: f.code(.existing)) == original)
        #expect(try Data(contentsOf: f.store.directory(for: f.work).appending(path: "config.json")) == login)
        #expect(try history.synchronize(to: f.work) == 0)
    }

    @Test func newerActivityWinsAndReplacementsHaveBackups() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing, activity: 1)
        try f.writeSession(f.work, activity: 2)
        let original = try Data(contentsOf: f.code(.existing))
        try ClaudeHistory(store: f.store).synchronize(to: .existing)
        #expect(try f.read(f.code(.existing))["lastActivityAt"] as? Int == 2)
        let backupRoot = f.store.root.appending(path: "history-backups")
        let backups = FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        let backedUp = try backups.filter { $0.pathExtension == "json" }.contains { try Data(contentsOf: $0) == original }
        #expect(backedUp)
    }

    @Test func deletedChatsAndProjectsAreNotResurrected() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        try f.write(["spaces": [["id": f.project, "name": "Project", "updatedAt": 1]]], to: f.spaces(.existing))
        let history = ClaudeHistory(store: f.store)
        try history.synchronize(to: f.work)
        try FileManager.default.removeItem(at: f.code(f.work))
        try f.write(["spaces": [], "untouchedRootKey": true], to: f.spaces(f.work))
        try history.synchronize(to: .existing)
        #expect(!FileManager.default.fileExists(atPath: f.code(.existing).path))
        #expect(try (f.read(f.spaces(.existing))["spaces"] as? [[String: Any]])?.isEmpty == true)
        try history.synchronize(to: f.work)
        #expect(!FileManager.default.fileExists(atPath: f.code(f.work).path))
        #expect(try f.read(f.spaces(f.work))["untouchedRootKey"] as? Bool == true)
    }

    @Test func corruptMetadataOrLinksStopBeforeAnyDestinationWrites() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        try f.writeSession(f.work)
        let target = try Data(contentsOf: f.code(f.work))
        try Data("invalid".utf8).write(to: f.code(.existing))
        #expect(throws: (any Error).self) { try ClaudeHistory(store: f.store).synchronize(to: f.work) }
        #expect(try Data(contentsOf: f.code(f.work)) == target)
        try FileManager.default.removeItem(at: f.code(.existing))
        try FileManager.default.createSymbolicLink(at: f.code(.existing), withDestinationURL: f.code(f.work))
        #expect(throws: (any Error).self) { try ClaudeHistory(store: f.store).synchronize(to: f.work) }
        #expect(try Data(contentsOf: f.code(f.work)) == target)
    }
}
