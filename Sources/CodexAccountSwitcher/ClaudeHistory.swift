import Foundation

// Only local Code sidebar records and project groupings are shared. Login and cloud data stay separate.
struct ClaudeHistory {
    struct Scope {
        let profile: ClaudeProfile
        let account: String
        let organization: String
        let code: URL
        let spaces: URL
        var key: String { "\(profile.id)/\(account)/\(organization)" }
    }

    struct Seen: Codable {
        var sessions: Set<String> = []
        var projects: Set<String> = []
    }

    struct State: Codable {
        var scopes: [String: Seen] = [:]
        var deletedSessions: Set<String> = []
        var deletedProjects: Set<String> = []
    }

    struct Record {
        let scope: Scope
        let value: [String: Any]
        let modified: Date
    }

    let store: ClaudeProfileStore
    private let files = FileManager.default

    func scopes(for profile: ClaudeProfile) throws -> [Scope] {
        let data = store.directory(for: profile)
        guard let account = try store.accountID(for: profile) else { return [] }
        var organizations = Set<String>()
        for tree in ["claude-code-sessions", "local-agent-mode-sessions"] {
            let directory = data.appending(path: tree).appending(path: account)
            for org in try children(directory) where UUID(uuidString: org.lastPathComponent) != nil {
                try check(org, directory: true)
                organizations.insert(org.lastPathComponent)
            }
        }
        return organizations.sorted().map { org in
            Scope(profile: profile, account: account, organization: org,
                  code: data.appending(path: "claude-code-sessions/\(account)/\(org)"),
                  spaces: data.appending(path: "local-agent-mode-sessions/\(account)/\(org)/spaces.json"))
        }
    }

    @discardableResult func synchronize(to target: ClaudeProfile) throws -> Int {
        let profiles = try store.load()
        guard profiles.contains(target) else { throw ClaudeProfileError.invalidRegistry }
        let targets = try scopes(for: target)
        guard !targets.isEmpty else { throw ClaudeProfileError.codeNotReady }
        var sources = profiles
        // Native launches still write here; include it only for an explicitly saved account.
        if !profiles.contains(where: { $0.id == ClaudeProfile.existing.id }),
           let account = try store.accountID(for: .existing),
           try profiles.contains(where: { try store.accountID(for: $0) == account }) {
            sources.append(.existing)
        }
        let all = try sources.flatMap { try scopes(for: $0) }
        let stateURL = store.root.appending(path: "history-state.json")
        var state = try files.fileExists(atPath: stateURL.path)
            ? JSONDecoder().decode(State.self, from: checkedData(stateURL)) : State()
        var sessions: [String: Record] = [:]
        var projects: [String: Record] = [:]
        var contents: [String: ([String: [String: Any]], [String: Any])] = [:]

        // Read and validate all metadata before changing any destination.
        for scope in all {
            let tracksDeletions = profiles.contains(scope.profile)
            if tracksDeletions, let previous = state.scopes[scope.key],
               (!previous.sessions.isEmpty && !files.fileExists(atPath: scope.code.path)) ||
                (!previous.projects.isEmpty && !files.fileExists(atPath: scope.spaces.path)) {
                throw ClaudeProfileError.invalidHistory
            }
            var entries: [String: [String: Any]] = [:]
            for url in try children(scope.code) where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
                let id = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: String(id.dropFirst(6))) != nil else { continue }
                let value = try object(url)
                guard value["sessionId"] as? String == id,
                      let cli = value["cliSessionId"] as? String, UUID(uuidString: cli) != nil,
                      value["lastActivityAt"] is NSNumber, value["cwd"] is String else {
                    throw ClaudeProfileError.invalidHistory
                }
                // Remote and isolated sessions need Claude's native import, not a copied local index.
                guard value["sshConfig"] == nil, value["wslConfig"] == nil,
                      !files.fileExists(atPath: scope.code.appending(path: id).path) else {
                    throw ClaudeProfileError.unsupportedHistory
                }
                if let old = sessions[id], old.value["cliSessionId"] as? String != cli {
                    throw ClaudeProfileError.invalidHistory
                }
                entries[id] = value
                let record = Record(scope: scope, value: value, modified: try modified(url))
                if newer(record, than: sessions[id], timeKey: "lastActivityAt") { sessions[id] = record }
            }
            var projectFile: [String: Any] = [:]
            if files.fileExists(atPath: scope.spaces.path) { projectFile = try object(scope.spaces) }
            guard projectFile["spaces"] == nil || projectFile["spaces"] is [[String: Any]] else {
                throw ClaudeProfileError.invalidHistory
            }
            let spaces = projectFile["spaces"] as? [[String: Any]] ?? []
            var projectIDs = Set<String>()
            for value in spaces {
                guard let id = value["id"] as? String, UUID(uuidString: id) != nil,
                      value["name"] is String, projectIDs.insert(id).inserted else {
                    throw ClaudeProfileError.invalidHistory
                }
                let record = Record(scope: scope, value: value, modified: try modified(scope.spaces))
                if newer(record, than: projects[id], timeKey: "updatedAt") { projects[id] = record }
            }
            let seen = Seen(sessions: Set(entries.keys), projects: projectIDs)
            if tracksDeletions, let previous = state.scopes[scope.key] {
                state.deletedSessions.formUnion(previous.sessions.subtracting(seen.sessions))
                state.deletedProjects.formUnion(previous.projects.subtracting(seen.projects))
            }
            if tracksDeletions { state.scopes[scope.key] = seen }
            contents[scope.key] = (entries, projectFile)
        }

        var writes: [(URL, Data?)] = []
        for targetScope in targets {
            let (existing, file) = contents[targetScope.key]!
            for (id, record) in sessions where !state.deletedSessions.contains(id) {
                var value = record.value
                if record.scope.account != targetScope.account || record.scope.organization != targetScope.organization {
                    // Account-bound cloud references and approvals must be rebuilt by the selected account.
                    for key in ["userSelectedProjectUuids", "remoteMcpServersConfig", "alwaysAllowedReasons",
                                "sessionPermissionUpdates", "promptAppendSnapshot", "toolSurfaceSnapshot",
                                "remoteControlAutoEligible", "steeredByRemoteClient", "envScopeId", "spawnSeed"] {
                        value.removeValue(forKey: key)
                    }
                    value["permissionMode"] = "default"
                    value.removeValue(forKey: "chromePermissionMode")
                }
                if !NSDictionary(dictionary: existing[id] ?? [:]).isEqual(to: value) {
                    writes.append((targetScope.code.appending(path: "\(id).json"), try encode(value)))
                }
            }
            for id in state.deletedSessions where existing[id] != nil {
                writes.append((targetScope.code.appending(path: "\(id).json"), nil))
            }
            var output = file
            let oldSpaces = file["spaces"] as? [[String: Any]] ?? []
            let oldByID = Dictionary(uniqueKeysWithValues: oldSpaces.map { ($0["id"] as! String, $0) })
            var merged: [[String: Any]] = []
            for id in projects.keys.sorted() where !state.deletedProjects.contains(id) {
                let record = projects[id]!
                var value = record.value
                if record.scope.account != targetScope.account || record.scope.organization != targetScope.organization {
                    for key in ["projects", "migration"] { value[key] = oldByID[id]?[key] }
                }
                merged.append(value)
            }
            if !NSArray(array: oldSpaces).isEqual(to: merged) {
                output["spaces"] = merged
                writes.append((targetScope.spaces, try encode(output)))
            }
            state.scopes[targetScope.key] = Seen(
                sessions: Set(sessions.keys).subtracting(state.deletedSessions),
                projects: Set(projects.keys).subtracting(state.deletedProjects))
        }

        // Keep originals before replacing/deleting metadata. Transcripts and project files are never edited.
        let backup = store.root.appending(path: "history-backups/\(UUID().uuidString)")
        for (index, write) in writes.enumerated() where files.fileExists(atPath: write.0.path) {
            try privateDirectory(backup)
            try checkedData(write.0).write(to: backup.appending(path: "\(index).json"), options: .atomic)
            try encode(["originalPath": write.0.path]).write(to: backup.appending(path: "\(index)-path.json"), options: .atomic)
        }
        for (url, data) in writes {
            try privateDirectory(url.deletingLastPathComponent())
            if let data {
                try data.write(to: url, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else { try files.removeItem(at: url) }
        }
        try privateDirectory(store.root)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        return writes.count
    }

    private func newer(_ a: Record, than b: Record?, timeKey: String) -> Bool {
        guard let b else { return true }
        let at = (a.value[timeKey] as? NSNumber)?.doubleValue ?? 0
        let bt = (b.value[timeKey] as? NSNumber)?.doubleValue ?? 0
        return at > bt || (at == bt && a.modified > b.modified)
    }

    private func children(_ directory: URL) throws -> [URL] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        try check(directory, directory: true)
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    private func check(_ url: URL, directory: Bool) throws {
        // Refuse links in the entire metadata path, including parent directories.
        var path = url
        while path.path != "/" {
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ClaudeProfileError.invalidHistory }
            path.deleteLastPathComponent()
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard directory ? values.isDirectory == true : values.isRegularFile == true && (values.fileSize ?? 0) <= 10_485_760 else {
            throw ClaudeProfileError.invalidHistory
        }
    }

    private func checkedData(_ url: URL) throws -> Data { try check(url, directory: false); return try Data(contentsOf: url) }
    private func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: checkedData(url)) as? [String: Any] else {
            throw ClaudeProfileError.invalidHistory
        }
        return value
    }
    private func encode(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func modified(_ url: URL) throws -> Date { try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast }
    private func privateDirectory(_ url: URL) throws {
        var existing = url
        while !files.fileExists(atPath: existing.path) { existing.deleteLastPathComponent() }
        try check(existing, directory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try check(url, directory: true)
    }
}
