import SwiftUI

struct ClaudeProfilesView: View {
    @ObservedObject var model: ClaudeProfilesModel
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    @State private var pending: ClaudeProfile?
    @State private var managesAccounts = false

    var body: some View {
        VStack(spacing: 0) {
            if managesAccounts {
                PopoverHeader(title: "Claude Accounts", backTitle: "Back") { managesAccounts = false }
                Divider()
            }
            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
            ScrollView {
                VStack(spacing: 2) {
                    if model.profiles.isEmpty {
                        Text("No Claude accounts added. Use Manage Accounts → Add Account to sign in.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(model.profiles) { profile in
                        Button { pending = profile } label: {
                            HStack(spacing: 10) {
                                Text(String(model.displayName(profile).prefix(1)).uppercased())
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .frame(width: 30, height: 30)
                                    .background(Color.primary.opacity(0.10), in: Circle())
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.displayName(profile))
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                        .help(model.displayName(profile))
                                    usageContent(profile)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .frame(minHeight: 50)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Switch to Claude account: \(model.displayName(profile))")
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 260)
            .disabled(model.isOpening || model.isAddingAccount)

            Divider()
            if managesAccounts && model.needsDetailsAccess {
                Button("Enable Email & Usage") {
                    Task { await model.refreshDetails(allowKeychainPrompt: true) }
                }
                .padding(10)
                .disabled(model.isRefreshingDetails || model.isAddingAccount || model.isOpening)
                Text("macOS may ask to allow access to Claude Safe Storage.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                Divider()
            }
            if managesAccounts {
                VStack(alignment: .leading, spacing: 7) {
                    if model.isAddingAccount {
                        HStack {
                            Button("Cancel Adding Account", action: model.cancelAddingAccount)
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                        Text("Complete sign-in in Claude, then open its Code tab. Your account will be saved automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button(action: model.addAccount) {
                            Label("Add Account", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isOpening)
                        Text("Claude will reopen for sign-in. Finish or stop active tasks first. Local Code chats and projects will be available after sign-in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            } else {
                HStack(spacing: 2) {
                    FooterAction(title: model.isAddingAccount ? "Finish Adding Account" : "Manage Accounts", systemImage: "person.2") {
                        managesAccounts = true
                    }
                    FooterAction(title: "Settings", systemImage: "gearshape", action: onSettings)
                    FooterAction(title: "Quit", systemImage: "power", action: onQuit)
                }
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(.plain)
                .padding(6)
                .disabled(model.isOpening)
            }
            if model.isOpening {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Switching Claude account…").font(.caption)
                }.padding(10)
            }
        }
        .task {
            model.load()
            while !Task.isCancelled {
                await model.refreshDetails()
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
            }
        }
        .confirmationDialog("Switch to \(pending.map(model.displayName) ?? "Claude")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { profile in
            Button("Switch Account") { Task { await model.open(profile) } }
        } message: { _ in
            Text("Finish or stop active tasks first. Claude will quit and reopen with the same local Code chats and project groupings. Continuing a chat sends its context under the selected account. Custom profiles may limit Chrome pairing.")
        }
    }

    @ViewBuilder private func usageContent(_ profile: ClaudeProfile) -> some View {
        let details = model.details[profile.id]
        let error = model.detailErrors[profile.id] ?? (model.needsDetailsAccess ? "Open Manage Accounts to enable email and usage." : nil)
        if let organization = details?.organizationName {
            Text(organization).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        if let weekly = details?.weekly {
            usageWindow("7d", weekly)
        }
        if let fiveHour = details?.fiveHour {
            usageWindow("5h", fiveHour)
        }
        if details?.weekly == nil && details?.fiveHour == nil {
            Text(model.isRefreshingDetails ? "Loading usage…" : "Usage unavailable")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .help(error ?? "Sign in to Claude and enable account details to load usage.")
        }
        if let error {
            Label(details?.updatedAt == nil ? "Could not refresh" : "Saved usage · could not refresh", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(.secondary).help(error)
        }
    }

    private func usageWindow(_ title: String, _ window: ClaudeAccountDetails.Window) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(title).frame(width: 18, alignment: .leading)
                UsageBar(remainingPercent: window.remainingPercent)
                Text("\(window.remainingPercent)% left").monospacedDigit().fixedSize()
            }
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(.relative(presentation: .numeric)))")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
