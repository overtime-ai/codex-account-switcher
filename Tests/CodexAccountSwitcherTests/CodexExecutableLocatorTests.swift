import Foundation
import Testing
@testable import SwitcherCore

struct CodexExecutableLocatorTests {
    @Test(arguments: [
        "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "Contents/Resources/codex-cli/bin/codex",
        "Contents/Resources/codex",
    ])
    func findsBundledCLIWithMissingOrBrokenPATHCommand(relativePath: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-desktop-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("ChatGPT.app")
        let executable = application.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let pathCommand = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: pathCommand, withDestinationURL: root.appendingPathComponent("missing-codex"))
        let locator = CodexExecutableLocator(desktopApplicationURLs: [application])
        for path in ["/nonexistent", bin.path] {
            #expect(try locator.locate(environment: ["PATH": path]) == executable)
        }
        #expect(try locator.locate(environment: ["PATH": bin.path, "CODEX_CLI_PATH": " "]) == executable)
        for override in ["codex", "custom-codex", root.appendingPathComponent("missing-codex").path] {
            #expect(throws: CodexClientError.self) {
                try locator.locate(environment: ["PATH": bin.path, "CODEX_CLI_PATH": override])
            }
        }

        try FileManager.default.removeItem(at: pathCommand)
        try FileManager.default.copyItem(at: executable, to: pathCommand)
        #expect(try locator.locate(environment: ["PATH": bin.path]) == pathCommand)
    }

    @Test func triesBundledLayoutsInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-desktop-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let layouts = [
            "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "Contents/Resources/codex-cli/bin/codex",
            "Contents/Resources/codex",
        ].map { root.appendingPathComponent($0) }
        for executable in layouts { try Self.writeExecutable(executable) }
        let locator = CodexExecutableLocator(desktopApplicationURLs: [root])
        for executable in layouts {
            #expect(try locator.locate(environment: [:]) == executable)
            try FileManager.default.removeItem(at: executable)
        }
    }

    @Test func replacesStaleDesktopCLIPathAfterDesktopUpdateMovesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-desktop-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("ChatGPT.app")
        let other = root.appendingPathComponent("Codex.app")
        let modern = application.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let otherCLI = other.appendingPathComponent("Contents/Resources/codex")
        let bin = root.appendingPathComponent("bin")
        let pathCommand = bin.appendingPathComponent("codex")
        for executable in [modern, otherCLI, pathCommand] {
            try Self.writeExecutable(executable)
        }
        // Desktop exported its pre-update layout into this process before the update removed it.
        let stale = application.appendingPathComponent("Contents/Resources/codex").path
        let locator = CodexExecutableLocator(desktopApplicationURLs: [other, application])
        for override in [stale, "\(application.path)/./Contents/Resources/codex",
                         root.path + "//ChatGPT.app/Contents/Resources/codex",
                         stale.replacingOccurrences(of: "ChatGPT.app", with: "chatgpt.APP")] {
            // The bundle the override names wins over both other bundles and a PATH command.
            #expect(try locator.locate(environment: ["PATH": bin.path, "CODEX_CLI_PATH": override]) == modern)
        }

        let shell = root.appendingPathComponent("login")
        try FileManager.default.createDirectory(at: shell, withIntermediateDirectories: true)
        let launch = try locator.launchConfiguration(environment: [
            "SHELL": "/bin/zsh", "HOME": shell.path, "ZDOTDIR": shell.path,
            "PATH": "/usr/bin:/bin", "CODEX_CLI_PATH": stale,
        ])
        #expect(launch.executable == modern)
        #expect(launch.environment["CODEX_CLI_PATH"] == modern.path)

        // An existing bundle and a removed override normalize the same way, even under /private.
        if application.path.hasPrefix("/var/") {
            let privateLocator = CodexExecutableLocator(desktopApplicationURLs: [
                URL(fileURLWithPath: "/private" + application.path),
            ])
            #expect(try privateLocator.locate(environment: ["CODEX_CLI_PATH": "/private" + stale]).path
                == "/private" + modern.path)
        }
        // A directory is not an executable, so Desktop's own resources directory is rescued too.
        let resources = application.appendingPathComponent("Contents/Resources/codex-cli").path
        #expect(try locator.locate(environment: ["PATH": "/nonexistent", "CODEX_CLI_PATH": resources]) == modern)

        // Every listed bundle is the same Desktop product, so another installed copy's CLI is used.
        try FileManager.default.removeItem(at: modern)
        #expect(try locator.locate(environment: ["PATH": "/nonexistent", "CODEX_CLI_PATH": stale]) == otherCLI)

        // Paths outside the Desktop bundles, look-alike siblings, directories and relative paths stay errors.
        for override in [root.appendingPathComponent("elsewhere/codex").path, bin.path,
                         String(stale.dropFirst()),
                         root.appendingPathComponent("ChatGPT.app.old/Contents/Resources/codex").path,
                         root.appendingPathComponent("ChatGPT.appX/Contents/Resources/codex").path] {
            #expect(throws: CodexClientError.processLaunchFailed("CODEX_CLI_PATH is not executable: \(override)")) {
                try locator.locate(environment: ["PATH": "/nonexistent", "CODEX_CLI_PATH": override])
            }
        }
        try FileManager.default.removeItem(at: otherCLI)
        #expect(throws: CodexClientError.processLaunchFailed("CODEX_CLI_PATH is not executable: \(stale)")) {
            try locator.locate(environment: ["PATH": "/nonexistent", "CODEX_CLI_PATH": stale])
        }
    }

    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"] + [fishPath].compactMap { $0 }, [false, true])
    func loginShellWithoutOverrideFallsBackToDesktopCLI(shell: String, nounset: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-shell-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let application = root.appendingPathComponent("ChatGPT.app")
        let bundled = application.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try Self.writeExecutable(bundled)
        let isFish = shell.hasSuffix("/fish")
        let startupName = isFish ? ".config/fish/config.fish"
            : shell.hasSuffix("/zsh") ? ".zprofile" : shell.hasSuffix("/bash") ? ".bash_profile" : ".profile"
        // nounset must not turn the unset override into a failed login-shell read. fish has no nounset.
        let startup = isFish ? "set -gx PATH /usr/bin /bin /usr/sbin /sbin\n"
            : (nounset ? (shell.hasSuffix("/zsh") ? "setopt nounset\n" : "set -u\n") : "")
                + "export PATH=\"/usr/bin:/bin:/usr/sbin:/sbin\"\n"
        let startupURL = root.appendingPathComponent(startupName)
        try FileManager.default.createDirectory(at: startupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(startup.utf8).write(to: startupURL)

        let launch = try CodexExecutableLocator(desktopApplicationURLs: [application]).launchConfiguration(environment: [
            "SHELL": shell, "HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin",
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config").path,
        ])
        #expect(launch.executable == bundled)
        #expect(launch.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(launch.environment["CODEX_CLI_PATH"] == bundled.path)
    }

    private static func writeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func readsPOSIXLoginShellConfiguration(shell: String) throws {
        try checkLoginShell(shell)
    }

    @Test(.enabled(if: fishPath != nil, "Install fish to run its login-shell regression check"))
    func readsFishLoginShellConfiguration() throws {
        try checkLoginShell(#require(Self.fishPath))
    }

    private static var fishPath: String? {
        ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func checkLoginShell(_ shell: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-shell-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin with spaces")
        let fishConfig = root.appendingPathComponent(".config/fish")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fishConfig, withIntermediateDirectories: true)
        for name in ["codex", "custom-codex"] {
            let executable = bin.appendingPathComponent(name)
            // The child must inherit the login PATH, including paths containing spaces.
            try Data("#!/bin/sh\nprintf '%s' \"$PATH\"\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        let isFish = shell.hasSuffix("/fish")
        let startupName = isFish ? ".config/fish/config.fish"
            : shell.hasSuffix("/zsh") ? ".zprofile"
            : shell.hasSuffix("/bash") ? ".bash_profile" : ".profile"
        let environment = [
            "SHELL": shell, "HOME": root.path, "ZDOTDIR": root.path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config").path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "FIXTURE_BIN": bin.path,
        ]
        for override in [nil, "", "custom-codex", bin.appendingPathComponent("custom-codex").path,
                         "/nonexistent/codex-shell-test"] as [String?] {
            var startup = isFish
                ? "set -gx PATH \"$FIXTURE_BIN\" /usr/bin /bin /usr/sbin /sbin\n"
                : "export PATH=\"$FIXTURE_BIN:/usr/bin:/bin:/usr/sbin:/sbin\"\n"
            if let override {
                // Deliberately leave the override unexported, as a shell-local setting.
                startup += isFish ? "set -g CODEX_CLI_PATH '\(override)'\n"
                    : "CODEX_CLI_PATH='\(override)'\n"
            }
            startup += "printf 'login startup output\\n'\n"
            try Data(startup.utf8).write(to: root.appendingPathComponent(startupName))

            if override?.hasPrefix("/nonexistent/") == true {
                #expect(throws: CodexClientError.processLaunchFailed(
                    "CODEX_CLI_PATH is not executable: \(override!)")) {
                    try CodexExecutableLocator(desktopApplicationURLs: []).launchConfiguration(environment: environment)
                }
                continue
            }

            let launch = try CodexExecutableLocator(desktopApplicationURLs: []).launchConfiguration(environment: environment)
            let expectedName = override == nil || override == "" ? "codex" : "custom-codex"
            #expect(launch.executable == bin.appendingPathComponent(expectedName))
            let expectedPATH = "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"
            #expect(launch.environment["PATH"] == expectedPATH)
            let child = Process()
            let output = Pipe()
            child.executableURL = launch.executable
            child.environment = launch.environment
            child.standardOutput = output
            try child.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            #expect(child.terminationStatus == 0)
            #expect(String(decoding: bytes, as: UTF8.self) == expectedPATH)
        }
    }
}
