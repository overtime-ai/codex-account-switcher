import Darwin
import Foundation

struct ClaudePins {
    static let origin = Data("_https://claude.ai\0".utf8)
    static let starredKey = key("LSS-persisted.starred-local-code-sessions")
    static let frameKey = key("LSS-persisted.dframe-local-slice")
    static let metadataKey = Data("META:https://claude.ai".utf8)
    static let versionKey = Data("VERSION".utf8)

    static func key(_ name: String) -> Data { origin + Data([1]) + Data(name.utf8) }

    static func synchronize(store: ClaudeProfileStore, from source: ClaudeProfile, to target: ClaudeProfile,
                            pins initialPins: [String: Bool], sourceIDs: Set<String>) throws -> [String: Bool] {
        guard !initialPins.isEmpty else { return initialPins }
        var pins = initialPins
        let files = FileManager.default
        let sourceDB = store.directory(for: source).appending(path: "Local Storage/leveldb")
        let targetDB = store.directory(for: target).appending(path: "Local Storage/leveldb")
        try checkPath(sourceDB)
        try checkPath(targetDB)
        let sourceConfig = try nativeConfig(store.directory(for: source))
        let targetConfig = try nativeConfig(store.directory(for: target))
        let sourcePrefs = try nativePins(sourceConfig.object)
        let targetPrefs = try nativePins(targetConfig.object)
        let targetExists = files.fileExists(atPath: targetDB.path)
        let targetLock = try targetExists ? DatabaseLock(targetDB) : nil
        let sourceLock = try sourceDB != targetDB && files.fileExists(atPath: sourceDB.path) ? DatabaseLock(sourceDB) : nil
        defer { withExtendedLifetime((targetLock, sourceLock)) {} }

        let backup = store.root.appending(path: "history-backups/pins-\(UUID().uuidString)")
        try checkPath(backup)
        try files.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = backup.appending(path: "leveldb")
        let sourceCopy = backup.appending(path: "source")
        var committed = false
        defer {
            try? files.removeItem(at: sourceCopy)
            if !committed { try? files.removeItem(at: backup) }
        }
        if targetExists { try copyDatabase(targetDB, to: staged) }
        else { try files.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        var sourceOrder: [String] = []
        if files.fileExists(atPath: sourceDB.path) {
            try copyDatabase(sourceDB, to: sourceCopy)
            let database = try ClaudePinDatabase(sourceCopy)
            var sourceStars: [String] = []
            if let data = try database.get(starredKey) {
                let starred = try envelope(data, defaultValue: [String]())
                guard let ids = starred["value"] as? [String] else { throw ClaudePinError.invalidSettings }
                sourceStars = ids
                let saved = Set(ids)
                for id in sourceIDs where pins[id] != nil { pins[id] = saved.contains(id) }
            }
            let frame = try envelope(database.get(frameKey), defaultValue: [String: Any]())
            guard let value = frame["value"] as? [String: Any],
                  value["pinnedOrder"] == nil || value["pinnedOrder"] is [String] else { throw ClaudePinError.invalidSettings }
            sourceOrder = (value["pinnedOrder"] as? [String] ?? []) + sourceStars.map { "code:\($0)" }
        }
        // Native preferences override the renderer's Local Storage mirror at startup.
        if let stars = sourcePrefs["starred-local-code-sessions"] as? [String] {
            let saved = Set(stars)
            for id in sourceIDs where pins[id] != nil { pins[id] = saved.contains(id) }
            let frame = sourcePrefs["dframe-local-slice"] as? [String: Any] ?? [:]
            sourceOrder = (frame["pinnedOrder"] as? [String] ?? []) + stars.map { "code:\($0)" }
        }
        let changed = try update(staged, pins: pins, sourceOrder: sourceOrder, create: !targetExists, native: targetPrefs)
        let database = try ClaudePinDatabase(staged)
        var config = targetConfig.object
        var preferences = config["preferences"] as? [String: Any] ?? [:]
        var native = targetPrefs
        native["starred-local-code-sessions"] = try envelope(database.get(starredKey), defaultValue: [String]())["value"]
        native["dframe-local-slice"] = try envelope(database.get(frameKey), defaultValue: [String: Any]())["value"]
        preferences["epitaxyPrefs"] = native
        config["preferences"] = preferences
        let configChanged = !NSDictionary(dictionary: config).isEqual(to: targetConfig.object)
        guard changed || configChanged else { return pins }
        if let original = targetConfig.data {
            try original.write(to: backup.appending(path: "claude_desktop_config.json"), options: .atomic)
        }
        try JSONSerialization.data(withJSONObject: ["originalPath": targetDB.path, "configPath": targetConfig.url.path])
            .write(to: backup.appending(path: "path.json"), options: .atomic)
        // Retain recovery files even if committing or rolling back either store fails.
        committed = true
        do {
            if configChanged {
                try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                    .write(to: targetConfig.url, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetConfig.url.path)
            }
            try files.createDirectory(at: targetDB.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            if targetExists {
                // Atomic exchange leaves the untouched original database at the backup path.
                guard renamex_np(staged.path, targetDB.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw ClaudePinError.database(String(cString: strerror(errno)))
                }
            } else { try files.moveItem(at: staged, to: targetDB) }
        } catch {
            if configChanged {
                if let original = targetConfig.data { try original.write(to: targetConfig.url, options: .atomic) }
                else if files.fileExists(atPath: targetConfig.url.path) { try files.removeItem(at: targetConfig.url) }
            }
            throw error
        }
        return pins
    }

    private static func update(_ directory: URL, pins: [String: Bool], sourceOrder: [String], create: Bool, native: [String: Any]) throws -> Bool {
        let database = try ClaudePinDatabase(directory, create: create)
        let version = try database.get(versionKey)
        guard version == Data("1".utf8) || (create && version == nil) else { throw ClaudePinError.invalidSettings }
        var starred = try envelope(database.get(starredKey), defaultValue: [String]())
        var frame = try envelope(database.get(frameKey), defaultValue: [String: Any]())
        let oldStarred = starred, oldFrame = frame
        if let value = native["starred-local-code-sessions"] { starred["value"] = value }
        if let value = native["dframe-local-slice"] { frame["value"] = value }
        guard let oldStars = starred["value"] as? [String], var frameValue = frame["value"] as? [String: Any],
              frameValue["pinnedOrder"] == nil || frameValue["pinnedOrder"] is [String] else { throw ClaudePinError.invalidSettings }
        let oldOrder = frameValue["pinnedOrder"] as? [String] ?? []
        let wanted = Set(pins.filter(\.value).keys)
        var ordered: [String] = []
        for entry in sourceOrder + oldOrder + wanted.sorted().map({ "code:\($0)" }) {
            guard entry.hasPrefix("code:") else { continue }
            let id = String(entry.dropFirst(5))
            if wanted.contains(id), !ordered.contains(id) { ordered.append(id) }
        }
        let newStars = ordered + oldStars.filter { pins[$0] == nil && !ordered.contains($0) }
        let newOrder = ordered.map { "code:\($0)" } + oldOrder.filter {
            !$0.hasPrefix("code:") || pins[String($0.dropFirst(5))] == nil
        }
        guard version == nil || newStars != oldStars || newOrder != oldOrder ||
              !NSDictionary(dictionary: oldStarred).isEqual(to: starred) ||
              !NSDictionary(dictionary: oldFrame).isEqual(to: frame) else { return false }
        starred["value"] = newStars
        frameValue["pinnedOrder"] = newOrder
        frame["value"] = frameValue
        let now = Date().timeIntervalSince1970
        starred["timestamp"] = Int64(now * 1_000)
        frame["timestamp"] = Int64(now * 1_000)
        var changes = [starredKey: try encode(starred), frameKey: try encode(frame)]
        // Chromium counts the encoded script keys and values, excluding the origin prefix.
        var delta = 0
        for (key, value) in changes {
            if let old = try database.get(key) { delta += value.count - old.count }
            else { delta += key.count - origin.count + value.count }
        }
        changes[metadataKey] = try adjustingSize(database.get(metadataKey), delta: delta, now: now)
        if version == nil { changes[versionKey] = Data("1".utf8) }
        try database.write(changes)
        for (key, expected) in changes {
            guard try database.get(key) == expected else { throw ClaudePinError.invalidSettings }
        }
        return true
    }

    private static func nativeConfig(_ directory: URL) throws -> (url: URL, data: Data?, object: [String: Any]) {
        let url = directory.appending(path: "claude_desktop_config.json")
        try checkPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return (url, nil, [:]) }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? 0) < 10_485_760 else { throw ClaudePinError.invalidSettings }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudePinError.invalidSettings }
        return (url, data, object)
    }

    private static func nativePins(_ object: [String: Any]) throws -> [String: Any] {
        guard object["preferences"] == nil || object["preferences"] is [String: Any] else { throw ClaudePinError.invalidSettings }
        let preferences = object["preferences"] as? [String: Any] ?? [:]
        guard preferences["epitaxyPrefs"] == nil || preferences["epitaxyPrefs"] is [String: Any] else { throw ClaudePinError.invalidSettings }
        let pins = preferences["epitaxyPrefs"] as? [String: Any] ?? [:]
        guard pins["starred-local-code-sessions"] == nil || pins["starred-local-code-sessions"] is [String],
              pins["dframe-local-slice"] == nil || pins["dframe-local-slice"] is [String: Any] else { throw ClaudePinError.invalidSettings }
        let frame = pins["dframe-local-slice"] as? [String: Any] ?? [:]
        guard frame["pinnedOrder"] == nil || frame["pinnedOrder"] is [String] else { throw ClaudePinError.invalidSettings }
        return pins
    }

    static func envelope(_ data: Data?, defaultValue: Any) throws -> [String: Any] {
        guard let data else { return ["value": defaultValue] }
        guard let marker = data.first, marker == 0 || marker == 1,
              let string = String(data: data.dropFirst(), encoding: marker == 1 ? .isoLatin1 : .utf16LittleEndian),
              let value = try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any], value["value"] != nil
        else { throw ClaudePinError.invalidSettings }
        return value
    }

    static func encode(_ envelope: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let string = String(decoding: json, as: UTF8.self)
        if let latin = string.data(using: .isoLatin1) { return Data([1]) + latin }
        return Data([0]) + string.data(using: .utf16LittleEndian)!
    }

    // Preserve unknown protobuf fields; only the existing size field changes.
    static func adjustingSize(_ original: Data?, delta: Int, now: TimeInterval) throws -> Data {
        guard let original else {
            guard delta >= 0 else { throw ClaudePinError.invalidSettings }
            return Data([8]) + varint(UInt64((now + 11_644_473_600) * 1_000_000)) + Data([16]) + varint(UInt64(delta))
        }
        let bytes = [UInt8](original)
        var index = 0, output = Data(), found = false
        func readVarint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw ClaudePinError.invalidSettings }
                let byte = bytes[index]; index += 1
                guard shift < 63 || byte <= 1 else { throw ClaudePinError.invalidSettings }
                value |= UInt64(byte & 127) << shift
                if byte < 128 { return value }
            }
            throw ClaudePinError.invalidSettings
        }
        while index < bytes.count {
            let start = index, tag = try readVarint()
            if tag == 16 {
                guard !found else { throw ClaudePinError.invalidSettings }
                let size = try readVarint()
                guard size <= UInt64(Int.max), Int(size) <= Int.max - max(delta, 0), Int(size) + delta >= 0 else {
                    throw ClaudePinError.invalidSettings
                }
                output += Data([16]) + varint(UInt64(Int(size) + delta)); found = true
                continue
            }
            switch tag & 7 {
            case 0: _ = try readVarint()
            case 1: index += 8
            case 2:
                let length = try readVarint()
                guard length <= UInt64(bytes.count - index) else { throw ClaudePinError.invalidSettings }
                index += Int(length)
            case 5: index += 4
            default: throw ClaudePinError.invalidSettings
            }
            guard index <= bytes.count else { throw ClaudePinError.invalidSettings }
            output.append(contentsOf: bytes[start..<index])
        }
        guard found else { throw ClaudePinError.invalidSettings }
        return output
    }

    private static func varint(_ input: UInt64) -> Data {
        var value = input, result = Data()
        while value > 127 { result.append(UInt8(value & 127) | 128); value >>= 7 }
        result.append(UInt8(value)); return result
    }

    private static func checkPath(_ url: URL) throws {
        var path = url
        while path.path != "/" {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ClaudePinError.invalidSettings
            }
            path.deleteLastPathComponent()
        }
    }

    private static func copyDatabase(_ source: URL, to target: URL) throws {
        guard let entries = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else {
            throw ClaudePinError.invalidSettings
        }
        for case let url as URL in entries {
            let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true else { throw ClaudePinError.invalidSettings }
        }
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    }

    private final class DatabaseLock {
        let descriptor: Int32
        init(_ directory: URL) throws {
            descriptor = Darwin.open(directory.appending(path: "LOCK").path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ClaudePinError.inUse }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
            guard fcntl(descriptor, F_SETLK, &lock) == 0 else {
                Darwin.close(descriptor)
                throw ClaudePinError.inUse
            }
        }
        deinit { Darwin.close(descriptor) }
    }
}
