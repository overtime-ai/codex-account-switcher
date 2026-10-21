import CommonCrypto
import Foundation
import LocalAuthentication
import Security

struct ClaudeAccountDetails: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let remainingPercent: Int
        let resetsAt: Date?
    }
    let accountID: String
    let email: String
    var organizationName: String?
    var weekly: Window?
    var fiveHour: Window?
    var updatedAt: Date?
    var usageError: String?
}

enum ClaudeDetailsError: LocalizedError {
    case keychain, encryption, login, identity, response, http(Int)
    var errorDescription: String? {
        switch self {
        case .keychain: "Allow access to Claude Safe Storage to show account emails and usage."
        case .encryption: "Claude's saved login format could not be read."
        case .login: "Open this account in Claude to renew its login, then refresh usage."
        case .identity: "Claude returned a different account identity. Its email and usage were not applied."
        case .response: "Claude did not provide usable account details."
        case let .http(status): "Claude account details are unavailable (HTTP \(status))."
        }
    }
}

// Chromium's macOS v10 safeStorage format; no credentials or encryption keys are written back.
struct ClaudeSafeStorage {
    static func key(allowPrompt: Bool) throws -> Data {
        var result: CFTypeRef?
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Claude Safe Storage",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else { throw ClaudeDetailsError.keychain }
        return try deriveKey(password: password)
    }

    static func deriveKey(password: Data) throws -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                salt.withUnsafeBytes { salt in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                        salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                        output.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDetailsError.encryption }
        return key
    }

    static func decrypt(_ encoded: String, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, let encrypted = Data(base64Encoded: encoded),
              encrypted.starts(with: Data("v10".utf8)), encrypted.count > 3 else { throw ClaudeDetailsError.encryption }
        let input = Data(encrypted.dropFirst(3))
        guard input.count >= kCCBlockSizeAES128, input.count % kCCBlockSizeAES128 == 0 else { throw ClaudeDetailsError.encryption }
        let iv = Data(repeating: 32, count: kCCBlockSizeAES128)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { output in
            input.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, kCCKeySizeAES128, iv.baseAddress, input.baseAddress, input.count,
                                output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeDetailsError.encryption }
        output.count = written
        return output
    }
}

private final class ClaudeNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ClaudeAccountReader {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let keyProvider: @Sendable (Bool) throws -> Data
    private var key: Data?

    init(keyProvider: @escaping @Sendable (Bool) throws -> Data = ClaudeSafeStorage.key,
         transport: @escaping Transport = ClaudeAccountReader.request) {
        self.keyProvider = keyProvider
        self.transport = transport
    }

    func read(configuration: [String: String], accountID: String, allowPrompt: Bool) async throws -> ClaudeAccountDetails {
        if key == nil {
            // Reuse macOS's existing grant after restart without allowing background prompts.
            key = try keyProvider(allowPrompt)
        }
        var entries: [String: Any] = [:]
        for name in ["oauth:tokenCache", "oauth:tokenCacheV2"] {
            if let encoded = configuration[name], !encoded.isEmpty {
                guard let cache = try JSONSerialization.jsonObject(with: ClaudeSafeStorage.decrypt(encoded, key: key!)) as? [String: Any] else {
                    throw ClaudeDetailsError.encryption
                }
                entries.merge(cache) { _, newer in newer }
            }
        }
        let token = try Self.token(entries: entries, accountID: accountID, now: Date())
        let profile = try await get("profile", token: token)
        let email = try Self.email(profile: profile, expectedAccountID: accountID)
        var result = ClaudeAccountDetails(accountID: accountID, email: email)
        result.organizationName = (profile["organization"] as? [String: Any])?["name"] as? String
        do {
            let usage = try await get("usage", token: token)
            result.weekly = try Self.window(usage["seven_day"])
            result.fiveHour = try Self.window(usage["five_hour"])
            guard result.weekly != nil || result.fiveHour != nil else { throw ClaudeDetailsError.response }
            result.updatedAt = Date()
        } catch { result.usageError = error.localizedDescription }
        return result
    }

    static func token(entries: [String: Any], accountID: String, now: Date) throws -> String {
        // Accept only explicitly account-scoped production tokens; legacy unscoped entries are ambiguous.
        let candidates = entries.compactMap { name, value -> (String, Double, Bool)? in
            guard name.lowercased().hasPrefix("acct:\(accountID.lowercased())|"),
                  name.contains(":https://api.anthropic.com:"),
                  let entry = value as? [String: Any], let token = entry["token"] as? String, !token.isEmpty,
                  let expiry = entry["expiresAt"] as? Double, expiry > now.timeIntervalSince1970 * 1000 else { return nil }
            return (token, expiry, name.contains("user:inference"))
        }.sorted { a, b in a.2 != b.2 ? a.2 : a.1 > b.1 }
        guard let selected = candidates.first else { throw ClaudeDetailsError.login }
        return selected.0
    }

    static func email(profile: [String: Any], expectedAccountID: String) throws -> String {
        guard let account = profile["account"] as? [String: Any],
              let id = account["uuid"] as? String, id.lowercased() == expectedAccountID.lowercased() else {
            throw ClaudeDetailsError.identity
        }
        guard let email = (account["email"] ?? account["email_address"]) as? String,
              email.contains("@"), email.count <= 254, !email.contains(where: { $0.isWhitespace }) else {
            throw ClaudeDetailsError.response
        }
        return email
    }

    static func window(_ raw: Any?) throws -> ClaudeAccountDetails.Window? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any] else { throw ClaudeDetailsError.response }
        guard let value = object["utilization"], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw ClaudeDetailsError.response
        }
        let percent = number.doubleValue
        var reset: Date?
        if let text = object["resets_at"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            guard reset != nil else { throw ClaudeDetailsError.response }
        }
        return .init(remainingPercent: Int((100 - min(100, max(0, percent))).rounded()), resetsAt: reset)
    }

    private func get(_ path: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(path)")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard response.statusCode == 200 else { throw ClaudeDetailsError.http(response.statusCode) }
        guard data.count <= 1_048_576, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeDetailsError.response
        }
        return value
    }

    private static func request(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ClaudeNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClaudeDetailsError.response }
        return (data, response)
    }
}
