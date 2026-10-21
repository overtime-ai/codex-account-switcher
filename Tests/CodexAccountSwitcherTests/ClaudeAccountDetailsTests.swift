import CommonCrypto
import Foundation
import Testing
@testable import CodexAccountSwitcher

struct ClaudeAccountDetailsTests {
    private let account = "11111111-1111-1111-1111-111111111111"

    @Test func decryptsChromiumV10FixtureAndRejectsUnsupportedOrCorruptData() throws {
        // Fixture generated independently with Python hashlib + OpenSSL AES-128-CBC.
        let key = try ClaudeSafeStorage.deriveKey(password: Data("fixture-password".utf8))
        #expect(key.base64EncodedString() == "XYToi40mKOIxArRk13pbvQ==")
        let decoded = try ClaudeSafeStorage.decrypt("djEw9QI6yoNoexE1KHktTIGDIaK0gX0XmybBuZYO+Cr+ACM=", key: key)
        #expect(String(data: decoded, encoding: .utf8) == "{\"fixture\":\"verified\"}")
        #expect(throws: ClaudeDetailsError.self) { try ClaudeSafeStorage.decrypt(Data("v20bad".utf8).base64EncodedString(), key: key) }
        #expect(throws: ClaudeDetailsError.self) { try ClaudeSafeStorage.decrypt("djEwAAAA", key: key) }
    }

    @Test func tokenSelectionRejectsOtherAccountsHostsAndExpiredEntries() throws {
        let now = Date(timeIntervalSince1970: 100)
        let prefix = "acct:\(account)|client:org:"
        let entries: [String: Any] = [
            prefix + "https://api.anthropic.com:user:profile": ["token": "profile", "expiresAt": 200_000.0],
            prefix + "https://api.anthropic.com:user:profile user:inference": ["token": "inference", "expiresAt": 150_000.0],
            prefix + "https://evil.invalid:user:inference": ["token": "wrong-host", "expiresAt": 900_000.0],
            "acct:other|client:org:https://api.anthropic.com:user:inference": ["token": "wrong-account", "expiresAt": 900_000.0],
        ]
        #expect(try ClaudeAccountReader.token(entries: entries, accountID: account, now: now) == "inference")
        #expect(throws: ClaudeDetailsError.self) { try ClaudeAccountReader.token(entries: entries, accountID: "other-account", now: now) }
        #expect(throws: ClaudeDetailsError.self) { try ClaudeAccountReader.token(entries: entries, accountID: account, now: Date(timeIntervalSince1970: 1000)) }
    }

    @Test func emailMustBelongToTheExpectedAccount() throws {
        let profile: [String: Any] = ["account": ["uuid": account, "email": "work@example.com"]]
        #expect(try ClaudeAccountReader.email(profile: profile, expectedAccountID: account) == "work@example.com")
        #expect(throws: ClaudeDetailsError.self) { try ClaudeAccountReader.email(profile: profile, expectedAccountID: "different") }
    }

    @Test func usageSupportsPartialWindowsAndValidatesResets() throws {
        #expect(try ClaudeAccountReader.window(NSNull()) == nil)
        #expect(try ClaudeAccountReader.window(["utilization": NSNull()]) == nil)
        let window = try ClaudeAccountReader.window(["utilization": 24.2, "resets_at": "2026-10-19T23:00:00.000Z"])
        #expect(window?.remainingPercent == 76)
        #expect(window?.resetsAt != nil)
        #expect(try ClaudeAccountReader.window(["utilization": 150])?.remainingPercent == 0)
        #expect(throws: ClaudeDetailsError.self) { try ClaudeAccountReader.window(["utilization": 20, "resets_at": "invalid"]) }
    }
}

private func encryptedAccountFixture(key: Data, account: String) throws -> String {
    let cache: [String: Any] = ["acct:\(account)|client:org:https://api.anthropic.com:user:profile user:inference":
        ["token": "synthetic-native-token", "expiresAt": Date.distantFuture.timeIntervalSince1970 * 1000]]
    let input = try JSONSerialization.data(withJSONObject: cache)
    let iv = Data(repeating: 32, count: kCCBlockSizeAES128)
    var output = Data(count: input.count + kCCBlockSizeAES128)
    let capacity = output.count
    var written = 0
    let status = output.withUnsafeMutableBytes { output in
        input.withUnsafeBytes { input in
            key.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            key.baseAddress, kCCKeySizeAES128, iv.baseAddress, input.baseAddress, input.count,
                            output.baseAddress, capacity, &written)
                }
            }
        }
    }
    guard status == kCCSuccess else { throw ClaudeDetailsError.encryption }
    output.count = written
    return (Data("v10".utf8) + output).base64EncodedString()
}

private actor ClaudeDetailsServer {
    let account = "11111111-1111-1111-1111-111111111111"
    var usageRequests = 0
    var requests = 0
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests += 1
        #expect(request.url?.host == "api.anthropic.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-native-token")
        #expect(request.httpMethod == "GET")
        let body: [String: Any]
        var status = 200
        if request.url!.path.hasSuffix("profile") {
            body = ["account": ["uuid": account, "email": "work@example.com"]]
        } else {
            usageRequests += 1
            status = usageRequests == 1 ? 200 : 503
            body = ["seven_day": ["utilization": 20, "resets_at": "2026-10-25T12:00:00Z"],
                    "five_hour": ["utilization": 35, "resets_at": "2026-10-19T22:00:00Z"]]
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

extension ClaudeAccountDetailsTests {
    @Test func backgroundRefreshDisallowsKeychainPrompts() async throws {
        let reader = ClaudeAccountReader(keyProvider: { allowPrompt in
            #expect(!allowPrompt)
            throw ClaudeDetailsError.keychain
        })
        await #expect(throws: ClaudeDetailsError.self) {
            try await reader.read(configuration: [:], accountID: account, allowPrompt: false)
        }
    }

    @MainActor @Test func verifiedEmailsPersistAndFailedRefreshKeepsLastGoodUsageWithoutCredentials() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClaudeProfileStore(root: root.appending(path: "switcher"), existingData: root.appending(path: "native"))
        try FileManager.default.createDirectory(at: store.existingData, withIntermediateDirectories: true)
        let key = try ClaudeSafeStorage.deriveKey(password: Data("test-key".utf8))
        let config: [String: Any] = ["lastKnownAccountUuid": account, "oauth:tokenCacheV2": try encryptedAccountFixture(key: key, account: account)]
        try JSONSerialization.data(withJSONObject: config).write(to: store.existingData.appending(path: "config.json"))
        let server = ClaudeDetailsServer()
        let reader = ClaudeAccountReader(keyProvider: { allowPrompt in
            guard allowPrompt else { throw ClaudeDetailsError.keychain }
            return key
        }, transport: { try await server.respond($0) })
        try store.save(.existing)
        let model = ClaudeProfilesModel(store: store, reader: reader)
        model.load()
        await model.refreshDetails()
        #expect(model.needsDetailsAccess)
        await model.refreshDetails(allowKeychainPrompt: true)
        #expect(!model.needsDetailsAccess)
        #expect(model.displayName(.existing) == "work@example.com")
        #expect(model.details[ClaudeProfile.existing.id]?.weekly?.remainingPercent == 80)
        #expect(model.details[ClaudeProfile.existing.id]?.fiveHour?.remainingPercent == 65)
        let updated = model.details[ClaudeProfile.existing.id]?.updatedAt
        await model.refreshDetails(allowKeychainPrompt: true)
        #expect(model.details[ClaudeProfile.existing.id]?.weekly?.remainingPercent == 80)
        #expect(model.details[ClaudeProfile.existing.id]?.updatedAt == updated)
        #expect(model.detailErrors[ClaudeProfile.existing.id]?.contains("503") == true)
        let saved = try String(contentsOf: store.root.appending(path: "account-details.json"), encoding: .utf8)
        #expect(saved.contains("work@example.com"))
        #expect(!saved.contains("synthetic-native-token"))
        #expect(!saved.contains("oauth:tokenCache"))
        let reloaded = ClaudeProfilesModel(store: store, reader: reader)
        reloaded.load()
        #expect(reloaded.displayName(.existing) == "work@example.com")
        // A new reader represents an app restart: existing permission must work silently.
        let restartedReader = ClaudeAccountReader(keyProvider: { allowPrompt in
            #expect(!allowPrompt)
            return key
        }, transport: { try await server.respond($0) })
        let restarted = ClaudeProfilesModel(store: store, reader: restartedReader)
        restarted.load()
        await restarted.refreshDetails()
        #expect(!restarted.needsDetailsAccess)
        #expect(restarted.displayName(.existing) == "work@example.com")
        #expect(restarted.details[ClaudeProfile.existing.id]?.weekly?.remainingPercent == 80)
        await model.refreshDetails()
        #expect(await server.requests == 6)
    }
}
