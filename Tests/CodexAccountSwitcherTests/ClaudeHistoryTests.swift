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
            try store.save(.existing)
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
        #expect(chat["permissionMode"] as? String == "auto")
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
        #expect(try f.read(f.code(.existing))["permissionMode"] as? String == "auto")
        let backupRoot = f.store.root.appending(path: "history-backups")
        let backups = FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        let backedUp = try backups.filter { $0.pathExtension == "json" }.contains { try Data(contentsOf: $0) == original }
        #expect(backedUp)
    }

    @Test func automaticModeAndPinsSurviveSwitchingWithoutCopyingToolApprovals() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        var value = try f.read(f.code(.existing))
        value["permissionMode"] = "auto"
        value["autoChosenInApp"] = true
        value["isStarred"] = true
        value["sessionPermissionUpdates"] = ["old approval"]
        try f.write(value, to: f.code(.existing))
        try ClaudeHistory(store: f.store).synchronize(to: f.work)
        let copied = try f.read(f.code(f.work))
        #expect(copied["permissionMode"] as? String == "auto")
        #expect(copied["autoChosenInApp"] as? Bool == true)
        #expect(copied["isStarred"] as? Bool == true)
        #expect(copied["alwaysAllowedReasons"] == nil)
        #expect(copied["sessionPermissionUpdates"] == nil)
    }

    @Test(arguments: [true, false])
    func outgoingPinsWinEvenWhenTheTargetHasNewerMessages(pinned: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing, activity: 1)
        try f.writeSession(f.work, activity: 2)
        for (profile, flag) in [(ClaudeProfile.existing, pinned), (f.work, !pinned)] {
            var value = try f.read(f.code(profile))
            value["isStarred"] = flag
            try f.write(value, to: f.code(profile))
        }
        let history = ClaudeHistory(store: f.store)
        try history.synchronize(to: f.work)
        #expect(try f.read(f.code(f.work))["lastActivityAt"] as? Int == 2)
        #expect(try f.read(f.code(f.work))["isStarred"] as? Bool == pinned)
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

    @Test(arguments: ["priorCliSessionIds", "priorRemoteCliSessionIds"], [false, true])
    func rotatedTranscriptsAndCurrentNativePinsTransferTogether(lineageKey: String, rotatedOnTarget: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let rotated = rotatedOnTarget ? f.work : .existing
        try f.writeSession(.existing, activity: rotatedOnTarget ? 10 : 1)
        try f.writeSession(f.work, activity: rotatedOnTarget ? 1 : 10)
        var value = try f.read(f.code(rotated))
        let oldCLI = value["cliSessionId"] as! String
        let newCLI = "88888888-8888-8888-8888-888888888888"
        value["cliSessionId"] = newCLI
        value[lineageKey] = [oldCLI]
        try f.write(value, to: f.code(rotated))
        let nativeURL = f.store.existingData.appending(path: "claude_desktop_config.json")
        try f.write(["preferences": ["epitaxyPrefs": ["starred-local-code-sessions": [f.session],
                     "dframe-local-slice": ["pinnedOrder": ["code:\(f.session)"]]]]], to: nativeURL)
        let original = try Data(contentsOf: f.code(.existing))
        let history = ClaudeHistory(store: f.store)
        try history.synchronize(to: f.work)
        #expect(try f.read(f.code(f.work))["cliSessionId"] as? String == newCLI)
        #expect(try f.read(f.code(f.work))[lineageKey] as? [String] == [oldCLI])
        #expect(try f.read(f.code(f.work))["isStarred"] as? Bool == true)
        #expect(try Data(contentsOf: f.code(.existing)) == original)
        let config = try f.read(f.store.directory(for: f.work).appending(path: "claude_desktop_config.json"))
        let prefs = (config["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any]
        #expect(prefs?["starred-local-code-sessions"] as? [String] == [f.session])
        let database = try ClaudePinDatabase(f.store.directory(for: f.work).appending(path: "Local Storage/leveldb"))
        #expect(try ClaudePins.envelope(database.get(ClaudePins.starredKey), defaultValue: [String]())["value"] as? [String] == [f.session])
        try f.store.recordOpened(f.work)
        try history.synchronize(to: .existing)
        #expect(try f.read(f.code(.existing))["cliSessionId"] as? String == newCLI)
        #expect(try f.read(f.code(.existing))["isStarred"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func unrelatedOrCyclicTranscriptIDsStillBlockBeforeWriting(cyclic: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        try f.writeSession(f.work)
        var source = try f.read(f.code(.existing))
        source["cliSessionId"] = "88888888-8888-8888-8888-888888888888"
        if cyclic {
            source["priorRemoteCliSessionIds"] = ["66666666-6666-6666-6666-666666666666"]
            var target = try f.read(f.code(f.work))
            target["priorRemoteCliSessionIds"] = [source["cliSessionId"] as! String]
            try f.write(target, to: f.code(f.work))
        }
        try f.write(source, to: f.code(.existing))
        let before = try Data(contentsOf: f.code(f.work))
        #expect(throws: ClaudeProfileError.self) { try ClaudeHistory(store: f.store).synchronize(to: f.work) }
        #expect(try Data(contentsOf: f.code(f.work)) == before)
        #expect(!FileManager.default.fileExists(atPath: f.store.root.appending(path: "history-backups").path))
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

    @Test func nativeHistoryForSavedAccountIsSharedWithoutRegisteringOrChangingDefault() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Match the real setup: only isolated accounts are registered, but native Claude has newer work.
        let saved = try f.store.add(name: "Saved native account")
        try f.write(["lastKnownAccountUuid": f.account], to: f.store.directory(for: saved).appending(path: "config.json"))
        let registry = f.store.root.appending(path: "profiles.json")
        try JSONEncoder().encode([saved, f.work]).write(to: registry)
        try f.writeSession(.existing, activity: 3)
        try f.writeSession(f.work, activity: 1)
        try f.write(["spaces": [["id": f.project, "name": "Native project", "updatedAt": 3]]], to: f.spaces(.existing))
        let original = try Data(contentsOf: f.code(.existing))
        let history = ClaudeHistory(store: f.store)
        try history.synchronize(to: f.work)
        #expect(try f.read(f.code(f.work))["lastActivityAt"] as? Int == 3)
        #expect(try (f.read(f.spaces(f.work))["spaces"] as? [[String: Any]])?.first?["name"] as? String == "Native project")
        #expect(try Data(contentsOf: f.code(.existing)) == original)
        #expect(try f.store.load() == [saved, f.work])

        // Missing native metadata must not propagate deletion into the saved profiles.
        try FileManager.default.removeItem(at: f.code(.existing))
        try history.synchronize(to: f.work)
        #expect(FileManager.default.fileExists(atPath: f.code(f.work).path))
    }

    @Test func unregisteredNativeAccountIsNotImported() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try JSONEncoder().encode([f.work]).write(to: f.store.root.appending(path: "profiles.json"))
        try f.writeSession(.existing)
        #expect(try ClaudeHistory(store: f.store).synchronize(to: f.work) == 0)
        #expect(!FileManager.default.fileExists(atPath: f.code(f.work).path))
    }

    @Test(arguments: ["wslConfig", "isolated"], [false, true])
    func unsharedSessionsStayInPlaceWhileLocalChatsSync(kind: String, remoteOnTarget: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        let profile = remoteOnTarget ? f.work : .existing
        let other = remoteOnTarget ? ClaudeProfile.existing : f.work
        let id = "local_77777777-7777-7777-7777-777777777777"
        let remote = f.code(profile).deletingLastPathComponent().appending(path: "\(id).json")
        var value = try f.read(f.code(.existing))
        value["sessionId"] = id
        if kind != "isolated" { value[kind] = ["host": "example.invalid"] }
        try f.write(value, to: remote)
        let payload = remote.deletingPathExtension().appending(path: "session-data.json")
        if kind == "isolated" { try f.write(["keep": true], to: payload) }
        let original = try Data(contentsOf: remote)
        let history = ClaudeHistory(store: f.store)
        let key = try #require(history.scopes(for: profile).first?.key)
        let stateURL = f.store.root.appending(path: "history-state.json")
        var state = ClaudeHistory.State()
        state.scopes[key] = ClaudeHistory.Seen(sessions: [id])
        state.deletedSessions = [id]
        try JSONEncoder().encode(state).write(to: stateURL)

        try history.synchronize(to: f.work)
        try history.synchronize(to: .existing)
        #expect(try Data(contentsOf: remote) == original)
        #expect(!FileManager.default.fileExists(atPath: f.code(other).deletingLastPathComponent().appending(path: "\(id).json").path))
        #expect(FileManager.default.fileExists(atPath: f.code(f.work).path))
        if kind == "isolated" { #expect(try f.read(payload)["keep"] as? Bool == true) }
        let saved = try JSONDecoder().decode(ClaudeHistory.State.self, from: Data(contentsOf: stateURL))
        #expect(!saved.deletedSessions.contains(id))
        #expect(saved.scopes.values.allSatisfy { !$0.sessions.contains(id) })
    }

    @Test(arguments: [false, true], [false, true])
    func pendingFirstStartStaysUntouchedAndTransfersAfterStarting(onTarget: Bool, nullID: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        let profile = onTarget ? f.work : .existing
        let other = onTarget ? ClaudeProfile.existing : f.work
        let id = "local_77777777-7777-7777-7777-777777777777"
        let url = f.code(profile).deletingLastPathComponent().appending(path: "\(id).json")
        let destination = f.code(other).deletingLastPathComponent().appending(path: "\(id).json")
        var value = try f.read(f.code(.existing))
        value["sessionId"] = id
        value["cliSessionId"] = nullID ? NSNull() : nil
        value["pendingFirstStart"] = ["prompt": "Synthetic pending request"]
        value["isStarred"] = true
        value["error"] = "You've hit your session limit"
        try f.write(value, to: url)
        let original = try Data(contentsOf: url)
        let history = ClaudeHistory(store: f.store)
        let key = try #require(history.scopes(for: profile).first?.key)
        var state = ClaudeHistory.State()
        state.scopes[key] = ClaudeHistory.Seen(sessions: [id])
        state.deletedSessions = [id]
        let stateURL = f.store.root.appending(path: "history-state.json")
        try JSONEncoder().encode(state).write(to: stateURL)

        try history.synchronize(to: f.work)
        try history.synchronize(to: .existing)
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let saved = try JSONDecoder().decode(ClaudeHistory.State.self, from: Data(contentsOf: stateURL))
        #expect(!saved.deletedSessions.contains(id))
        #expect(saved.scopes.values.allSatisfy { !$0.sessions.contains(id) })

        value["cliSessionId"] = "88888888-8888-8888-8888-888888888888"
        value.removeValue(forKey: "pendingFirstStart")
        try f.write(value, to: url)
        try history.synchronize(to: other)
        #expect(try f.read(destination)["sessionId"] as? String == id)
    }

    @Test(arguments: [false, true])
    func missingOrMalformedTranscriptIDWithoutAPendingRequestStillBlocksSync(malformed: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        var value = try f.read(f.code(.existing))
        if malformed {
            value["cliSessionId"] = "invalid"
            value["pendingFirstStart"] = ["prompt": "Synthetic pending request"]
        } else { value.removeValue(forKey: "cliSessionId") }
        try f.write(value, to: f.code(.existing))
        let history = ClaudeHistory(store: f.store)
        #expect(throws: ClaudeProfileError.self) { try history.synchronize(to: f.work) }
        #expect(!FileManager.default.fileExists(atPath: f.code(f.work).path))
    }

    @Test func localAliasCannotOverwriteUnsharedSessionOrPropagateItsDeletion() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing, activity: 1)
        try f.writeSession(f.work, activity: 2)
        var remote = try f.read(f.code(.existing))
        remote["wslConfig"] = ["distribution": "test"]
        try f.write(remote, to: f.code(.existing))
        let originalRemote = try Data(contentsOf: f.code(.existing))
        let originalLocal = try Data(contentsOf: f.code(f.work))
        let history = ClaudeHistory(store: f.store)
        try history.synchronize(to: .existing)
        try history.synchronize(to: f.work)
        #expect(try Data(contentsOf: f.code(.existing)) == originalRemote)
        #expect(try Data(contentsOf: f.code(f.work)) == originalLocal)

        try FileManager.default.removeItem(at: f.code(.existing))
        try history.synchronize(to: f.work)
        #expect(try f.read(f.code(f.work))["cliSessionId"] as? String == "66666666-6666-6666-6666-666666666666")
        #expect(try f.read(f.code(f.work))["permissionMode"] as? String == "auto")
    }

    @Test func sshThreadMovesWithItsPinAndHistoryButWithoutTheOldReconnectTicket() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        var value = try f.read(f.code(.existing))
        value["sshConfig"] = ["sshHost": "devbox"]
        value["sshRemoteTranscriptPath"] = "/home/user/.claude/projects/repo/transcript.jsonl"
        value["sshRemoteProcessId"] = "old-native-process"
        value["sshReattach"] = ["processId": "old-native-process", "state": "live"]
        value["isStarred"] = true
        try f.write(value, to: f.code(.existing))
        let original = try Data(contentsOf: f.code(.existing))
        let history = ClaudeHistory(store: f.store)
        try history.synchronize(to: f.work)
        let copied = try f.read(f.code(f.work))
        #expect((copied["sshConfig"] as? [String: String])?["sshHost"] == "devbox")
        #expect(copied["sshRemoteTranscriptPath"] as? String == value["sshRemoteTranscriptPath"] as? String)
        #expect(copied["cliSessionId"] as? String == value["cliSessionId"] as? String)
        #expect(copied["sshRemoteProcessId"] as? String == "old-native-process")
        #expect(copied["sshReattach"] == nil)
        #expect(copied["permissionMode"] as? String == "auto")
        #expect(try Data(contentsOf: f.code(.existing)) == original)
    }

    @Test func targetedSSHImportDoesNotRewriteAdvancedChatsAndRefusesAnExistingDestination() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.writeSession(.existing)
        var ssh = try f.read(f.code(.existing))
        ssh["sshConfig"] = ["sshHost": "devbox"]
        try f.write(ssh, to: f.code(.existing))
        let advanced = f.code(f.work).deletingLastPathComponent().appending(path: "local_77777777-7777-7777-7777-777777777777.json")
        let progress = Data("advanced chat bytes must stay untouched".utf8)
        try progress.write(to: advanced)
        let source = try Data(contentsOf: f.code(.existing))
        let history = ClaudeHistory(store: f.store)
        let imported = try history.importSSHSession(f.session, from: .existing, to: f.work)
        #expect(try Data(contentsOf: advanced) == progress)
        #expect(try Data(contentsOf: f.code(.existing)) == source)
        let first = try Data(contentsOf: imported)
        #expect(throws: (any Error).self) { try history.importSSHSession(f.session, from: .existing, to: f.work) }
        #expect(try Data(contentsOf: imported) == first)
        #expect(try Data(contentsOf: advanced) == progress)
    }

}
