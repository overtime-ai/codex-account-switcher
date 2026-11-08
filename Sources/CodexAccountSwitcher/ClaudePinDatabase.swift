import CLevelDB
import Foundation

enum ClaudePinError: LocalizedError {
    case invalidSettings, database(String), inUse
    var errorDescription: String? {
        switch self {
        case .invalidSettings: "Claude's saved pin settings have an unsupported format. The original settings were preserved."
        case .database(let message): "Could not update Claude's saved pins: \(message)"
        case .inUse: "Claude's settings are still in use. Close Claude normally before switching accounts."
        }
    }
}

// The same LevelDB/Snappy format Chromium uses; never repair or salvage a damaged database.
final class ClaudePinDatabase {
    private let handle: OpaquePointer

    init(_ directory: URL, create: Bool = false) throws {
        let options = leveldb_options_create()!
        defer { leveldb_options_destroy(options) }
        leveldb_options_set_create_if_missing(options, create ? 1 : 0)
        leveldb_options_set_paranoid_checks(options, 1)
        var error: UnsafeMutablePointer<CChar>?
        let opened = leveldb_open(options, directory.path, &error)
        try Self.check(error)
        guard let opened else { throw ClaudePinError.invalidSettings }
        handle = opened
    }

    deinit { leveldb_close(handle) }

    func get(_ key: Data) throws -> Data? {
        let options = leveldb_readoptions_create()!
        defer { leveldb_readoptions_destroy(options) }
        leveldb_readoptions_set_verify_checksums(options, 1)
        var count = 0
        var error: UnsafeMutablePointer<CChar>?
        let bytes = key.withUnsafeBytes {
            leveldb_get(handle, options, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, &count, &error)
        }
        defer { if let bytes { leveldb_free(bytes) } }
        try Self.check(error)
        return bytes.map { Data(bytes: $0, count: count) }
    }

    func write(_ values: [Data: Data]) throws {
        let batch = leveldb_writebatch_create()!
        let options = leveldb_writeoptions_create()!
        defer { leveldb_writebatch_destroy(batch); leveldb_writeoptions_destroy(options) }
        leveldb_writeoptions_set_sync(options, 1)
        for (key, value) in values {
            key.withUnsafeBytes { k in value.withUnsafeBytes { v in
                leveldb_writebatch_put(batch, k.baseAddress?.assumingMemoryBound(to: CChar.self), k.count,
                                      v.baseAddress?.assumingMemoryBound(to: CChar.self), v.count)
            } }
        }
        var error: UnsafeMutablePointer<CChar>?
        leveldb_write(handle, options, batch, &error)
        try Self.check(error)
    }

    func entries() throws -> [Data: Data] {
        let options = leveldb_readoptions_create()!
        leveldb_readoptions_set_verify_checksums(options, 1)
        let iterator = leveldb_create_iterator(handle, options)!
        defer { leveldb_iter_destroy(iterator); leveldb_readoptions_destroy(options) }
        var result: [Data: Data] = [:]
        leveldb_iter_seek_to_first(iterator)
        while leveldb_iter_valid(iterator) != 0 {
            var keySize = 0, valueSize = 0
            let key = leveldb_iter_key(iterator, &keySize)!
            let value = leveldb_iter_value(iterator, &valueSize)!
            result[Data(bytes: key, count: keySize)] = Data(bytes: value, count: valueSize)
            leveldb_iter_next(iterator)
        }
        var error: UnsafeMutablePointer<CChar>?
        leveldb_iter_get_error(iterator, &error)
        try Self.check(error)
        return result
    }

    private static func check(_ error: UnsafeMutablePointer<CChar>?) throws {
        if let error {
            defer { leveldb_free(error) }
            throw ClaudePinError.database(String(cString: error))
        }
    }
}
