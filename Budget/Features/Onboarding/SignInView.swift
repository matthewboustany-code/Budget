import SwiftUI
import AuthenticationServices

/// Sign in with Apple. In DEBUG builds it also offers a dev sign-in that hits
/// the server's AUTH_DEV_MODE path, so the whole flow works on the simulator
/// without an Apple Developer account / entitlement.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Budget")
                    .font(.largeTitle.bold())
                Text("Track your money together.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let message = env.authStore.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .disabled(env.authStore.isWorking)

            #if DEBUG
            VStack(spacing: 8) {
                Text("Developer sign-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Sign in as Alice") { Task { await env.authStore.devSignIn(as: "Alice") } }
                    Button("Sign in as Bob") { Task { await env.authStore.devSignIn(as: "Bob") } }
                }
                .buttonStyle(.bordered)
                .disabled(env.authStore.isWorking)
            }
            .padding(.top, 4)
            #endif

            if env.authStore.isWorking { ProgressView() }
        }
        .padding(32)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                env.authStore.errorMessage = "Apple didn't return an identity token."
                return
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            Task { await env.authStore.signInWithApple(identityToken: token,
                                                       fullName: name.isEmpty ? nil : name) }
        case .failure(let error):
            // User-cancelled (code 1001) is silent; surface anything else.
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                env.authStore.errorMessage = error.localizedDescription
            }
        }
    }
}
