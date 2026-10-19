import SwiftUI

struct ClaudeProfilesView: View {
    @ObservedObject var model: ClaudeProfilesModel
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
                    ForEach(model.profiles) { profile in
                        Button { pending = profile } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "person.crop.circle")
                                Text(profile.name).lineLimit(2)
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(8)
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Switch to Claude account: \(profile.name)")
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 220)
            .disabled(model.isOpening || model.isAddingAccount)

            Divider()
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
                Button { managesAccounts = true } label: {
                    Label(model.isAddingAccount ? "Finish Adding Account" : "Manage Accounts", systemImage: "person.2")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Rectangle())
                }
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
        .task { model.load() }
        .confirmationDialog("Switch to \(pending?.name ?? "Claude")?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { profile in
            Button("Switch Account") { Task { await model.open(profile) } }
        } message: { _ in
            Text("Finish or stop active tasks first. Claude will quit and reopen with the same local Code chats and project groupings. Continuing a chat sends its context under the selected account. Custom profiles may limit Chrome pairing.")
        }
    }
}
