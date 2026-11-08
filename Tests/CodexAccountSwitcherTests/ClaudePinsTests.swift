import Foundation
import Testing
@testable import CodexAccountSwitcher

struct ClaudePinsTests {
    private struct Fixture {
        let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
        let store: ClaudeProfileStore
        let source: ClaudeProfile
        let target: ClaudeProfile
        init() throws {
            store = ClaudeProfileStore(root: root.appending(path: "profiles"), existingData: root.appending(path: "existing"))
            source = try store.add(name: "Source")
            target = try store.add(name: "Target")
        }
        func database(_ profile: ClaudeProfile) -> URL {
            store.directory(for: profile).appending(path: "Local Storage/leveldb")
        }
        func seed(_ profile: ClaudeProfile, stars: [String], order: [String], other: [Data: Data] = [:]) throws {
            let url = database(profile)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let db = try ClaudePinDatabase(url, create: true)
            var values = other
            values[ClaudePins.versionKey] = Data("1".utf8)
            values[ClaudePins.starredKey] = try ClaudePins.encode(["value": stars, "timestamp": 123, "tabId": "keep-tab"])
            values[ClaudePins.frameKey] = try ClaudePins.encode(["value": ["pinnedOrder": order, "sidebarWidth": 317, "futureSetting": "keep"], "timestamp": 456])
            let size = values.filter { $0.key.starts(with: ClaudePins.origin) }
                .reduce(0) { $0 + $1.key.count - ClaudePins.origin.count + $1.value.count }
            values[ClaudePins.metadataKey] = try ClaudePins.adjustingSize(nil, delta: size, now: 0)
            try db.write(values)
        }
        func entries(_ profile: ClaudeProfile) throws -> [Data: Data] { try ClaudePinDatabase(database(profile)).entries() }
    }

    @Test func mergesPinKeysAndOrderWhilePreservingEveryOtherSettingAndSource() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = "local_11111111-1111-1111-1111-111111111111", b = "local_22222222-2222-2222-2222-222222222222"
        let c = "local_33333333-3333-3333-3333-333333333333", isolated = "local_44444444-4444-4444-4444-444444444444"
        try f.seed(f.source, stars: [a, b], order: ["code:\(b)", "code:\(a)"])
        let opaque = Data("unrelated-opaque-key".utf8)
        try f.seed(f.target, stars: [c, isolated], order: ["chat:cloud-pin", "code:\(c)", "code:\(isolated)"],
                   other: [opaque: Data([0, 255, 21]), ClaudePins.key("unrelated"): Data([1, 12, 42])])
        let sourceBefore = try f.entries(f.source), targetBefore = try f.entries(f.target)
        let resolved = try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target,
                                                   pins: [a: false, b: false, c: true], sourceIDs: [a, b, c])
        #expect(resolved == [a: true, b: true, c: false])
        let after = try f.entries(f.target)
        let allowed = Set([ClaudePins.starredKey, ClaudePins.frameKey, ClaudePins.metadataKey])
        #expect(after.filter { !allowed.contains($0.key) } == targetBefore.filter { !allowed.contains($0.key) })
        #expect(try f.entries(f.source) == sourceBefore)
        let stars = try ClaudePins.envelope(after[ClaudePins.starredKey], defaultValue: [])
        #expect(stars["value"] as? [String] == [b, a, isolated])
        #expect((stars["timestamp"] as? Int ?? 0) > 123)
        #expect(stars["tabId"] as? String == "keep-tab")
        let frame = try ClaudePins.envelope(after[ClaudePins.frameKey], defaultValue: [:])
        let value = try #require(frame["value"] as? [String: Any])
        #expect(value["pinnedOrder"] as? [String] == ["code:\(b)", "code:\(a)", "chat:cloud-pin", "code:\(isolated)"])
        #expect(value["sidebarWidth"] as? Int == 317)
        #expect(value["futureSetting"] as? String == "keep")
        let backups = try FileManager.default.contentsOfDirectory(at: f.store.root.appending(path: "history-backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try ClaudePinDatabase(backups[0].appending(path: "leveldb")).entries() == targetBefore)
        _ = try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target,
                                      pins: resolved, sourceIDs: [a, b, c])
        #expect(try f.entries(f.target) == after)
    }

    @Test func nativePreferencesWinOverStaleMirrorsAndSurviveStartup() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = "local_11111111-1111-1111-1111-111111111111", b = "local_22222222-2222-2222-2222-222222222222"
        try f.seed(f.source, stars: [b], order: ["code:\(b)"])
        try f.seed(f.target, stars: [], order: [])
        let source: [String: Any] = ["preferences": ["epitaxyPrefs": ["starred-local-code-sessions": [a], "dframe-local-slice": ["pinnedOrder": ["code:\(a)"]]]]]
        let target: [String: Any] = ["mcpServers": ["keep": ["command": "test"]], "preferences": ["sidebarMode": "keep", "epitaxyPrefs": ["unrelated": "keep", "starred-local-code-sessions": [], "dframe-local-slice": ["pinnedOrder": [], "homeProjectsPinnedOrder": ["keep-project"]]]]]
        let sourceURL = f.store.directory(for: f.source).appending(path: "claude_desktop_config.json")
        let targetURL = f.store.directory(for: f.target).appending(path: "claude_desktop_config.json")
        let sourceData = try JSONSerialization.data(withJSONObject: source)
        let targetData = try JSONSerialization.data(withJSONObject: target)
        try sourceData.write(to: sourceURL)
        try targetData.write(to: targetURL)
        let resolved = try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target,
                                                 pins: [a: false, b: true], sourceIDs: [a, b])
        #expect(resolved == [a: true, b: false])
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: targetURL)) as? [String: Any])
        var expected = target
        var preferences = target["preferences"] as! [String: Any]
        var native = preferences["epitaxyPrefs"] as! [String: Any]
        native["starred-local-code-sessions"] = [a]
        native["dframe-local-slice"] = ["pinnedOrder": ["code:\(a)"], "homeProjectsPinnedOrder": ["keep-project"]]
        preferences["epitaxyPrefs"] = native; expected["preferences"] = preferences
        #expect(NSDictionary(dictionary: saved).isEqual(to: expected))
        // Claude's startup prefers the native bucket over the Local Storage mirror.
        let mirror = try ClaudePins.envelope(f.entries(f.target)[ClaudePins.starredKey], defaultValue: [])
        #expect(native["starred-local-code-sessions"] as? [String] == mirror["value"] as? [String])
        #expect(try Data(contentsOf: sourceURL) == sourceData)
        let backups = try FileManager.default.contentsOfDirectory(at: f.store.root.appending(path: "history-backups"), includingPropertiesForKeys: nil)
        #expect(try Data(contentsOf: backups[0].appending(path: "claude_desktop_config.json")) == targetData)
    }

    @Test(arguments: ["malformed", "symlink", "bad-pins"])
    func invalidNativePreferencesDoNotChangeDestination(kind: String) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.source, stars: [], order: [])
        try f.seed(f.target, stars: [], order: [])
        let url = f.store.directory(for: f.target).appending(path: "claude_desktop_config.json")
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.database(f.source))
        } else {
            try Data((kind == "malformed" ? "{" : "{\"preferences\":{\"epitaxyPrefs\":{\"starred-local-code-sessions\":false}}}").utf8).write(to: url)
        }
        let before = try f.entries(f.target)
        #expect(throws: (any Error).self) {
            try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target,
                                      pins: ["local_11111111-1111-1111-1111-111111111111": true], sourceIDs: [])
        }
        #expect(try f.entries(f.target) == before)
    }

    @Test(arguments: ["symlink", "bad-json", "bad-version"])
    func invalidSettingsLeaveTheOriginalDatabaseUntouched(kind: String) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.source, stars: [], order: [])
        try f.seed(f.target, stars: [], order: [])
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: f.database(f.target).appending(path: "unexpected"), withDestinationURL: f.database(f.source))
        } else {
            let db = try ClaudePinDatabase(f.database(f.target))
            try db.write([kind == "bad-json" ? ClaudePins.starredKey : ClaudePins.versionKey: Data("invalid".utf8)])
        }
        let before = try f.entries(f.target)
        #expect(throws: (any Error).self) {
            try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target,
                                       pins: ["local_11111111-1111-1111-1111-111111111111": true], sourceIDs: [])
        }
        #expect(try f.entries(f.target) == before)
    }

    @Test func sourceStarredOrderIsUsedWhenTheFrameHasNoPinOrder() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let a = "local_11111111-1111-1111-1111-111111111111", b = "local_22222222-2222-2222-2222-222222222222"
        try f.seed(f.source, stars: [b, a], order: [])
        try f.seed(f.target, stars: [], order: [])
        _ = try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target, pins: [a: true, b: true], sourceIDs: [a, b])
        let frame = try ClaudePins.envelope(f.entries(f.target)[ClaudePins.frameKey], defaultValue: [:])
        #expect((frame["value"] as? [String: Any])?["pinnedOrder"] as? [String] == ["code:\(b)", "code:\(a)"])
    }

    @Test func refusesALockedDatabaseWithoutWaitingOrRewritingIt() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.target, stars: [], order: [])
        let before = try f.entries(f.target)
        let child = Process(), ready = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX); print('R',flush=True); time.sleep(15)", f.database(f.target).appending(path: "LOCK").path]
        child.standardOutput = ready
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        #expect(throws: ClaudePinError.self) {
            try ClaudePins.synchronize(store: f.store, from: f.source, to: f.target,
                                       pins: ["local_11111111-1111-1111-1111-111111111111": true], sourceIDs: [])
        }
        child.terminate(); child.waitUntilExit()
        #expect(try f.entries(f.target) == before)
    }

    @Test func metadataSizeUpdatesPreserveUnknownFieldsAndRejectMalformedData() throws {
        #expect(try ClaudePins.adjustingSize(Data([8, 4, 16, 100, 26, 2, 65, 66]), delta: -20, now: 0) == Data([8, 4, 16, 80, 26, 2, 65, 66]))
        for bytes: [UInt8] in [[16, 1], [16, 128], [26, 99], [16, 1, 16, 1]] {
            #expect(throws: ClaudePinError.self) { try ClaudePins.adjustingSize(Data(bytes), delta: -2, now: 0) }
        }
        let unicode = ["value": ["pin": "🌙"]]
        let decoded = try ClaudePins.envelope(ClaudePins.encode(unicode), defaultValue: [:])
        #expect((decoded["value"] as? [String: String])?["pin"] == "🌙")
    }
}
