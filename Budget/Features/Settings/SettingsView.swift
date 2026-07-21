import SwiftUI

/// P0 settings: shows the backend URL and connection status, and a disabled
/// sign-out row (auth arrives in P1). Later phases add household members, the
/// invite flow, and connection management here.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section("Backend") {
                LabeledContent("Server", value: ServerConfig.baseURL.absoluteString)
                ConnectionRow(status: env.connectionStatus)
                Button("Recheck connection") {
                    Task { await env.checkConnection() }
                }
            }

            Section("Account") {
                LabeledContent("Signed in", value: env.session.isSignedIn ? "Yes" : "Not yet")
                Button("Sign out", role: .destructive) {
                    env.session.signOut()
                }
                .disabled(!env.session.isSignedIn)
            }
        }
        .navigationTitle("Settings")
    }
}
