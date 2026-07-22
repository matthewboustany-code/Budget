import SwiftUI
import BudgetModels

/// Household members, the partner-invite flow, backend status, and sign-out.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showInvite = false

    var body: some View {
        List {
            if let household = env.session.household {
                Section("Household") {
                    LabeledContent("Name", value: household.name)
                }

                Section("Members") {
                    ForEach(env.session.members) { member in
                        MemberRow(member: member,
                                  isMe: member.id == env.session.member?.id)
                    }
                    Button {
                        showInvite = true
                        Task { await env.householdStore.generateInvite() }
                    } label: {
                        Label("Invite partner", systemImage: "person.badge.plus")
                    }
                }
            }

            Section("You") {
                LabeledContent("Name", value: env.session.member?.displayName
                               ?? env.session.user?.displayName ?? "—")
                if let email = env.session.user?.email {
                    LabeledContent("Apple ID", value: email)
                }
            }

            Section("Backend") {
                LabeledContent("Server", value: ServerConfig.baseURL.absoluteString)
                ConnectionRow(status: env.connectionStatus)
                Button("Recheck connection") {
                    Task { await env.checkConnection() }
                }
            }

            Section {
                Button("Sign out", role: .destructive) {
                    env.session.signOut()
                }
            }
        }
        .navigationTitle("Settings")
        .task { await env.checkConnection() }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
        }
    }
}

/// Health-check status line (previously lived on the P0 dashboard; the
/// Monarch-style home has no backend plumbing, so it moved here for good).
struct ConnectionRow: View {
    let status: AppEnvironment.ConnectionStatus

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(status.label)
                .font(.callout)
        }
    }

    private var symbol: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .ok: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

private struct MemberRow: View {
    let member: HouseholdMember
    let isMe: Bool

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(member.displayName + (isMe ? " (you)" : ""))
                Text(member.role.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Bottom sheet showing the freshly generated invite code to share.
private struct InviteSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if env.householdStore.isWorking {
                    ProgressView("Generating code…")
                } else if let invite = env.householdStore.latestInvite {
                    Text("Share this code with your partner")
                        .font(.headline)
                    Text(invite.code)
                        .font(.system(.largeTitle, design: .monospaced).bold())
                        .textSelection(.enabled)
                    ShareLink(item: "Join our Budget household with code \(invite.code)") {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("The code can be used once and expires in 7 days.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let message = env.householdStore.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Invite partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
