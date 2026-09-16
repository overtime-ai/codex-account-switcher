> **Overtime fork:** Application update checks, downloads, installation, notifications, and controls have been removed on both macOS and Windows. This fork does not contact the upstream update service. Account login and usage refresh through Codex still work. Build from this repository; upstream binaries do not contain these changes. See [fork maintenance](docs/overtime-fork.md).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/account-switcher-logo-white.png">
    <img src="assets/account-switcher-logo.png" width="96" height="96" alt="Codex Account Switcher logo">
  </picture>
</p>

<h1 align="center">Codex Account Switcher</h1>

<p align="center">
  <strong>Switch Codex accounts on macOS and Windows.</strong><br>
  Add accounts once, then choose when you need them. No Terminal commands or config-file editing.
</p>

<p align="center">
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-171513?logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-171513">
  <img alt="Windows 10/11 x64" src="https://img.shields.io/badge/Windows-10%2F11%20x64-171513">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-171513"></a>
</p>

<p align="center">
  <a href="#development"><b>Build for Mac</b></a> ·
  <a href="windows/README.md"><b>Build for Windows</b></a> ·
  <a href="https://liuzhao1225.github.io/codex-account-switcher/"><b>Website</b></a> ·
  <a href="https://github.com/liuzhao1225/codex-account-switcher/discussions"><b>Discussions</b></a>
</p>

<p align="center">
  English · <a href="README.zh-CN.md">中文</a>
</p>

![Native macOS Codex Account Switcher showing three fictional Codex profiles, usage, and account switching from the menu bar](assets/codex-account-switcher-hero.png)

<p align="center">
  <a href="#build-and-install">Installation</a> &nbsp; / &nbsp;
  <a href="#features">Features</a> &nbsp; / &nbsp;
  <a href="#frequently-asked-questions">FAQ</a> &nbsp; / &nbsp;
  <a href="#development">Development</a>
</p>

<p align="center">Created and maintained by <a href="https://liuzhao1225.github.io/codex-account-switcher/about/creator/">Zhao Liu (GitHub: liuzhao1225)</a> · <a href="https://x.com/liuzhao_666">X</a> · <a href="https://space.bilibili.com/1263732318">Bilibili</a></p>

Codex Account Switcher is a free, open-source app for managing multiple authorized Codex accounts on macOS and Windows. Add personal, work, or client accounts through the browser once, then choose the account you need in the app. The everyday workflow requires no coding knowledge, Terminal commands, copied tokens, or config-file editing.

After you select and confirm an account, the app closes Codex Desktop, completes the account handoff, verifies the selected identity, and reopens Desktop. Saved account data stays on your computer. The app runs without its own proxy, traffic router, cloud account service, or automatic account rotation.

## Official project identity

**Codex Account Switcher**, also called **Codex Switcher** in shortened descriptions, is created and maintained by **Zhao Liu**, whose GitHub username is **liuzhao1225**. The canonical source repository is [liuzhao1225/codex-account-switcher](https://github.com/liuzhao1225/codex-account-switcher). The [official project facts](https://liuzhao1225.github.io/codex-account-switcher/about/), [creator profile](https://liuzhao1225.github.io/codex-account-switcher/about/creator/), and [project identity record](https://github.com/liuzhao1225/codex-account-switcher/blob/main/docs/project-identity.md) document the product, author, aliases, release, and primary sources.

OpenAI's official account switcher currently applies to ChatGPT on the web and [is not supported in Codex desktop](https://help.openai.com/en/articles/20001068-use-multiple-accounts-with-account-switching). Codex Account Switcher is an independent local macOS and Windows utility for that desktop workflow. OpenAI's upstream Codex source documents the active `CODEX_HOME` and file-based `auth.json` behavior in its [authentication storage implementation](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs).

## Who it is for

- **People with personal and work accounts:** keep both identities ready on one computer and see which account is active before opening Codex Desktop.
- **Freelancers and consultants:** keep authorized client accounts together and choose the correct identity before starting work.
- **Desktop users who prefer visible controls:** use a normal app workflow with visible account selection and confirmation instead of scripts or hidden automatic rotation.

## Build and install

This fork is based on upstream v0.1.12 and has no published release binaries yet. Build the Mac application using the [development instructions](#development), or follow the [Windows build instructions](windows/README.md). Upstream downloads include the updater removed here.

macOS requires macOS 14+ and Apple Silicon. Windows requires Windows 10/11 x64. Both platforms need an available Codex runtime and must use the same active Codex home as Codex Desktop.

## Features

| Feature | What it gives you |
| --- | --- |
| **No-code setup** | Add accounts through the normal browser sign-in flow, with no Terminal commands or config files. |
| **Native account controls** | Use the macOS menu bar or a Windows window with a system-tray entry point. |
| **Completed Desktop handoff** | Select and confirm an account, then let the app close, switch, verify, and reopen Codex Desktop. |
| **Local account storage** | Keep saved account data on your computer without an app-owned proxy or cloud account service. |
| **Usage at a glance** | Check weekly allowance by default, or enable the exact 300-minute (5-hour) service window and reset time in Settings. The optional row is off by default. |
| **Native apps on both platforms** | SwiftUI on macOS and WPF on Windows, with English and Simplified Chinese interfaces. |

## How it works

1. **Download for your platform:** install the macOS DMG or run the portable Windows EXE.
2. **Add each account once:** complete the familiar browser sign-in; the app derives the account name from the login identity.
3. **Choose and continue:** select an account in the app, confirm, and let the app reopen Codex Desktop.

Existing terminal processes keep their current runtime state. Start a new Codex CLI process to use the newly selected account.

## Feedback wanted

The product is being shaped for ordinary desktop users. Join the public discussion, [“What still feels too technical in a Codex account switcher for Mac?”](https://github.com/liuzhao1225/codex-account-switcher/discussions/2), and tell us whether the friction is downloading the app, adding an account, seeing the active account, or understanding the switch confirmation.

Comparisons with other account switchers are welcome. Please describe the workflow you actually use and the step that creates friction; never share credentials, account files, email addresses, or private screenshots.

## Privacy and scope

- Saved account data stays in user-only local directories on your computer.
- Each saved profile contains a complete, reusable `auth.json` credential snapshot. macOS uses mode `0700` for profile directories and `0600` for credentials; Windows uses current-user ACLs. Both platforms replace credential files atomically.
- Local file permissions define the current security boundary. User backups, filesystem snapshots, cloud backup tools, endpoint software, and other processes with access to the user's files may copy the saved credential snapshots.
- Removing an account performs ordinary filesystem deletion. The app makes no secure-erasure guarantee for SSD storage, APFS snapshots, or backups.
- Both platforms use file-backed credential storage; macOS does not store profile credentials in Keychain.
- The product runs without its own account proxy, traffic router, or cloud account service.
- Every account is selected and confirmed by the user; the app does not rotate accounts automatically.
- The project is independent open-source software and is not affiliated with or endorsed by OpenAI.
- The current account appears through a row highlight inside the popover.
- Persisted 5-hour and weekly usage remains visible while fresh data loads; the 5-hour row appears only when enabled and the service provides an exact 300-minute window.
- Every switch stops immediately on the first reported error.
- If target verification or the registry commit fails after credential activation, the app restores the just-saved original profile credential while preserving the original error. A restoration error is reported alongside it.
- General rollback state machines, retries, credential backup files, recovery journals, startup recovery, and policy-based routing stay outside the product scope.

## Release status

This fork has no published release binaries yet. The table describes release workflow outputs; Mac signing and notarization require this repository's own credentials.

macOS and Windows share one version and **`v<version>`** tag. Every release rebuilds, tests, and packages both platforms from the same commit, then publishes once both pass. The current MVP reuses neither older packages nor build caches across runs.

| Platform | Package | Updates |
| --- | --- | --- |
| macOS | Signed, notarized DMG and SHA-256 checksum | Manual replacement only; no in-app updater |
| Windows | Portable EXE and SHA-256 checksum; EXE currently unsigned | Manual replacement only; no in-app updater |

Every Release includes both platform downloads, uses the version as its title, and lists only changes in its notes. See [release management](docs/platform-releases.md) and [Windows development](windows/README.md).

## Development

<a href="https://github.com/overtime-ai/codex-account-switcher/actions/workflows/release.yml"><img alt="Release workflow" src="https://github.com/overtime-ai/codex-account-switcher/actions/workflows/release.yml/badge.svg"></a>

Both apps share a Swift 6.2 account core, with native SwiftUI on macOS and WPF on Windows. The commands below build macOS; see [Windows development](windows/README.md) for Windows.

```bash
git clone https://github.com/overtime-ai/codex-account-switcher.git
cd codex-account-switcher
swift build
swift test
./scripts/run-core-checks.sh
```

Create a local macOS app bundle:

```bash
./scripts/package-local-app.sh
```

The bundle is written to `.build/release/Codex Account Switcher.app`.

### Automated releases

Push a matching `v*` tag from a tested main commit to publish. The version in `CITATION.cff`, the Mac packaging default, the Codex client, and `windows/Directory.Build.props` must agree. Ordinary main pushes run CI only.

GitHub Actions tests and packages both platforms from the same tag. The publish job waits for both, verifies checksums, uploads the DMG and EXE to a draft, then publishes one Latest release. macOS retains Developer ID signing, Apple notarization (after fork signing secrets are configured). Release notes list only changes. See [release management](docs/platform-releases.md).

### Project map

```text
Sources/CodexAccountSwitcher/   Native macOS SwiftUI app and system adapters
Sources/SwitcherCore/           Shared account state, switching, usage, RPC and localization
Sources/SwitcherHost/           Private stdio host for the Windows native client
Sources/SwitcherPlatform/       Windows filesystem permissions and atomic replacement
windows/                       Native Windows tray UI, adapters, checks and packaging
Tests/                              Swift tests for storage, client, switching, and login items
Checks/                             Standalone core behavior checks
scripts/                            Local packaging and verification commands
docs/                               Product, system, implementation, and testing documentation
prototype/                          Early browser-based visual prototype
```

## Contributing

Use [GitHub Discussions](https://github.com/liuzhao1225/codex-account-switcher/discussions) for workflow questions, product ideas, and comparisons. Use [GitHub Issues](https://github.com/liuzhao1225/codex-account-switcher/issues) for bug reports and focused feature proposals. Run the following checks before opening a pull request:

The website records the project's [privacy model](https://liuzhao1225.github.io/codex-account-switcher/privacy/), [official contact channels](https://liuzhao1225.github.io/codex-account-switcher/contact/), and [responsible-use terms](https://liuzhao1225.github.io/codex-account-switcher/terms/). Do not post secrets or private account data in public support channels.

```bash
swift test
./scripts/run-core-checks.sh
```

Keep real `auth.json` files, account names, email addresses, API credentials, and private screenshots out of issues, commits, test fixtures, and documentation.

## Documentation

- [Documentation index](docs/README.md)
- [Official project identity and primary sources](docs/project-identity.md)
- [Product positioning and messaging](docs/positioning-and-messaging.md)
- [Product decisions](docs/product-decisions.md)
- [Product requirements](docs/product-requirements.md)
- [System design](docs/system-design.md)
- [Implementation plan](docs/implementation-plan.md)
- [Testing](docs/testing.md)
- [LLM-readable project index](https://liuzhao1225.github.io/codex-account-switcher/llms.txt)

## Frequently asked questions

### Do I need Terminal or coding knowledge?

No. Install the app, add each account through a normal browser sign-in, then choose in the app. There are no Terminal commands or config files to edit.

### How do I switch accounts?

Add each authorized account once. Finish or stop active Desktop tasks, then select the account in the app and confirm. If Desktop displays its quit dialog, complete it. The app waits up to 30 seconds for normal exit, completes the handoff, verifies the selected account, and reopens Desktop. If Desktop cannot exit, switching stops before the account changes.

### Does it switch accounts automatically?

You choose and confirm every account. The app then completes the Codex Desktop handoff automatically. It does not rotate accounts in the background or switch based on usage thresholds.

### Does my account data leave my computer?

Saved account data stays in user-only local folders: `~/Library/Application Support/Codex Account Switcher/` on macOS and `%LOCALAPPDATA%\Codex Account Switcher\` on Windows. The app has no account proxy, traffic router, or cloud profile service.

### Which systems are supported?

The app supports Apple Silicon Macs running macOS 14+ and Windows 10/11 x64. Both downloads are available in the same latest Release.

### Is Codex Account Switcher an official OpenAI product?

No. It is an independent MIT-licensed open-source project for macOS and Windows.

## License

Codex Account Switcher is released under the [MIT License](LICENSE).

## Updates

Updates are managed manually in this fork. Neither platform checks for new versions, downloads updates, or installs them. The Mac build contains no Sparkle framework or update-feed configuration. Windows has no update HTTP client or timer. Old automatic-update preferences are ignored because the updater code has been removed.

No release binaries were produced as part of the fork change. Build from this source, or use a future release published by `overtime-ai`. Installing an upstream release restores upstream update behavior.
