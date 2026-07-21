import SwiftUI

/// After signing in, the user either creates a household or joins their
/// partner's with an invite code.
struct HouseholdSetupView: View {
    @Environment(AppEnvironment.self) private var env

    private enum Mode: String, CaseIterable { case create = "Create", join = "Join" }
    @State private var mode: Mode = .create
    @State private var householdName = ""
    @State private var displayName = ""
    @State private var inviteCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Your name") {
                    TextField("e.g. Alex", text: $displayName)
                        .textContentType(.givenName)
                }

                switch mode {
                case .create:
                    Section("Household name") {
                        TextField("e.g. Our Home", text: $householdName)
                    }
                    Section {
                        Text("You'll be able to invite your partner with a code once your household is created.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .join:
                    Section("Invite code") {
                        TextField("BUDGET-XXXXXX", text: $inviteCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                }

                if let message = env.householdStore.errorMessage {
                    Section { Text(message).foregroundStyle(.red).font(.footnote) }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            Text(mode == .create ? "Create household" : "Join household")
                            if env.householdStore.isWorking {
                                Spacer(); ProgressView()
                            }
                        }
                    }
                    .disabled(!isValid || env.householdStore.isWorking)
                }
            }
            .navigationTitle("Set up")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out") { env.session.signOut() }
                }
            }
        }
    }

    private var isValid: Bool {
        let hasName = !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        switch mode {
        case .create: return hasName && !householdName.trimmingCharacters(in: .whitespaces).isEmpty
        case .join: return hasName && !inviteCode.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        Task {
            switch mode {
            case .create:
                await env.householdStore.createHousehold(name: householdName, displayName: displayName)
            case .join:
                await env.householdStore.join(code: inviteCode, displayName: displayName)
            }
        }
    }
}
