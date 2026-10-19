import AppKit
import Combine
import Foundation

struct ClaudeProfile: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String

    static let existing = ClaudeProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "Existing Claude"
    )
}

// Store profile names and paths only. Claude owns login cookies, Keychain access, and history.
struct ClaudeProfileStore {
    let root: URL
    let existingData: URL
    private let files = FileManager.default

    init(root: URL? = nil, existingData: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appending(path: "Codex Account Switcher/claude-desktop")
        self.existingData = existingData ?? support.appending(path: "Claude")
    }

    func directory(for profile: ClaudeProfile) -> URL {
        profile.id == ClaudeProfile.existing.id ? existingData : root.appending(path: profile.id.uuidString)
    }

    func load() throws -> [ClaudeProfile] {
        let registry = root.appending(path: "profiles.json")
        guard files.fileExists(atPath: registry.path) else { return [.existing] }
        let saved = try JSONDecoder().decode([ClaudeProfile].self, from: Data(contentsOf: registry))
        guard Set(saved.map(\.id)).count == saved.count,
              !saved.contains(where: { $0.id == ClaudeProfile.existing.id || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw ClaudeProfileError.invalidRegistry }
        return [.existing] + saved
    }

    func add(name: String) throws -> ClaudeProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ClaudeProfileError.invalidName }
        let profiles = try load()
        guard !profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ClaudeProfileError.duplicateName
        }
        let profile = try createPending(name: name)
        try save(profile)
        return profile
    }

    func createPending(name: String = "New account") throws -> ClaudeProfile {
        let profile = ClaudeProfile(id: UUID(), name: name)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try files.createDirectory(at: directory(for: profile), withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        return profile
    }

    func save(_ profile: ClaudeProfile) throws {
        let profiles = try load()
        guard !profiles.contains(where: { $0.id == profile.id }) else { throw ClaudeProfileError.invalidRegistry }
        let data = try JSONEncoder().encode(Array(profiles.dropFirst()) + [profile])
        try data.write(to: root.appending(path: "profiles.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appending(path: "profiles.json").path)
    }

    func lastOpened() throws -> ClaudeProfile {
        let path = root.appending(path: "last-opened.json")
        guard files.fileExists(atPath: path.path) else { return .existing }
        let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: path))
        return try load().first(where: { $0.id == id }) ?? .existing
    }

    func recordOpened(_ profile: ClaudeProfile) throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profile.id).write(to: root.appending(path: "last-opened.json"), options: .atomic)
    }

    func accountID(for profile: ClaudeProfile) throws -> String? {
        guard let object = try configuration(for: profile),
              let id = object["lastKnownAccountUuid"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }

    private func configuration(for profile: ClaudeProfile) throws -> [String: Any]? {
        let config = directory(for: profile).appending(path: "config.json")
        guard files.fileExists(atPath: config.path) else { return nil }
        let values = try config.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 10_485_760,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any] else {
            throw ClaudeProfileError.invalidRegistry
        }
        return object
    }

    func signedInProfile(_ profile: ClaudeProfile) throws -> ClaudeProfile? {
        guard let config = try configuration(for: profile),
              ["oauth:tokenCacheV2", "oauth:tokenCache"].contains(where: { !(config[$0] as? String ?? "").isEmpty }) else { return nil }
        guard let id = try accountID(for: profile), try !ClaudeHistory(store: self).scopes(for: profile).isEmpty else { return nil }
        let known = try load().filter { $0.id != profile.id }
        guard try !known.contains(where: { try accountID(for: $0) == id }) else { throw ClaudeProfileError.duplicateAccount }
        return ClaudeProfile(id: profile.id, name: "Claude · \(id.prefix(8))")
    }

    func launchArguments(for profile: ClaudeProfile, pending: Bool = false) throws -> [String] {
        guard try pending || load().contains(profile) else { throw ClaudeProfileError.invalidRegistry }
        if profile.id == ClaudeProfile.existing.id { return [] }
        let directory = directory(for: profile)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ClaudeProfileError.missingDirectory
        }
        return ["--user-data-dir=\(directory.path)"]
    }
}

enum ClaudeProfileError: LocalizedError {
    case invalidRegistry, invalidName, duplicateName, missingDirectory, appMissing, quitFailed
    case codeNotReady, invalidHistory, unsupportedHistory, duplicateAccount

    var errorDescription: String? {
        switch self {
        case .invalidRegistry: "Claude's saved profile list is invalid. Your Claude data has not been changed."
        case .invalidName: "Enter a profile name between 1 and 80 characters."
        case .duplicateName: "That profile name already exists. Choose another name."
        case .missingDirectory: "This profile's data folder is missing or is a link. Restore the original folder before opening it."
        case .appMissing: "Install the Claude desktop app before opening a profile."
        case .quitFailed: "Claude did not finish quitting. Finish or stop active tasks, close Claude, and try again. Your saved profiles have not changed."
        case .codeNotReady: "Open the Code tab in this Claude account once, then try switching again."
        case .invalidHistory: "Claude's local history metadata is invalid or contains a link. Switching stopped; restore the metadata before retrying."
        case .unsupportedHistory: "A remote or isolated Code session needs Claude's native import. Switching stopped without changing history."
        case .duplicateAccount: "This Claude account is already saved. Choose it from the account list."
        }
    }
}

@MainActor
protocol ClaudeDesktopControlling {
    func close() async throws
    func launch(arguments: [String]) async throws
}

struct ClaudeDesktopController: ClaudeDesktopControlling {
    func close() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
        for application in running where !application.isTerminated {
            guard application.terminate() || application.isTerminated else { throw ClaudeProfileError.quitFailed }
        }
        do {
            try await DesktopQuitWaiter().wait {
                !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").isEmpty
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ClaudeProfileError.quitFailed }
    }

    func launch(arguments: [String]) async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            throw ClaudeProfileError.appMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }
}

@MainActor
final class ClaudeProfilesModel: ObservableObject {
    @Published private(set) var profiles: [ClaudeProfile] = []
    @Published private(set) var isOpening = false
    @Published private(set) var isAddingAccount = false
    @Published var error: String?
    private let store: ClaudeProfileStore
    private let desktop: any ClaudeDesktopControlling
    private var addTask: Task<Void, Never>?
    private var lastOpened: ClaudeProfile = .existing

    init(store: ClaudeProfileStore = ClaudeProfileStore(), desktop: any ClaudeDesktopControlling = ClaudeDesktopController()) {
        self.store = store
        self.desktop = desktop
    }

    func load() {
        do {
            profiles = try store.load()
            lastOpened = try store.lastOpened()
        }
        catch { self.error = error.localizedDescription }
    }

    func addAccount() {
        guard !isOpening, !isAddingAccount else { return }
        isAddingAccount = true
        error = nil
        addTask = Task {
            await performAddAccount()
            isAddingAccount = false
            addTask = nil
        }
    }

    func cancelAddingAccount() { addTask?.cancel() }

    private func performAddAccount() async {
        let previous = lastOpened
        var signInLaunched = false
        do {
            let pending = try store.createPending()
            let arguments = try store.launchArguments(for: pending, pending: true)
            try await desktop.close()
            signInLaunched = true
            try Task.checkCancellation()
            try await desktop.launch(arguments: arguments + ["claude://code"])
            while true {
                try Task.checkCancellation()
                if let profile = try store.signedInProfile(pending) {
                    try await desktop.close()
                    try Task.checkCancellation()
                    try store.save(profile)
                    profiles = try store.load()
                    try ClaudeHistory(store: store).synchronize(to: profile)
                    try await desktop.launch(arguments: try store.launchArguments(for: profile))
                    lastOpened = profile
                    try store.recordOpened(profile)
                    return
                }
                try await Task.sleep(for: .milliseconds(750))
            }
        } catch {
            let original = error
            if signInLaunched {
                // Cancellation must not cancel the attempt to restore the previous desktop profile.
                let restoration = Task { @MainActor in
                    try await desktop.close()
                    try await desktop.launch(arguments: try store.launchArguments(for: previous))
                }
                do { try await restoration.value }
                catch { self.error = "\(original.localizedDescription) Reopening the previous account failed: \(error.localizedDescription)"; return }
            }
            if !(original is CancellationError) { self.error = original.localizedDescription }
        }
    }

    func open(_ profile: ClaudeProfile) async {
        guard !isOpening, !isAddingAccount else { return }
        isOpening = true
        error = nil
        defer { isOpening = false }
        let previous = lastOpened
        var closed = false
        do {
            // Validate everything before asking Claude to quit.
            let arguments = try store.launchArguments(for: profile)
            try await desktop.close()
            closed = true
            try ClaudeHistory(store: store).synchronize(to: profile)
            try await desktop.launch(arguments: arguments)
            lastOpened = profile
            try store.recordOpened(profile)
        } catch {
            let original = error
            if closed, lastOpened == previous {
                do { try await desktop.launch(arguments: try store.launchArguments(for: previous)) }
                catch { self.error = "\(original.localizedDescription) Reopening the previous account failed: \(error.localizedDescription)"; return }
            }
            self.error = original.localizedDescription
        }
    }
}
