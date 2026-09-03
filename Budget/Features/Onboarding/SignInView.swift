import SwiftUI
import AuthenticationServices
import CryptoKit

/// Sign in with Apple. In DEBUG builds it also offers a dev sign-in that hits
/// the server's AUTH_DEV_MODE path, so the whole flow works on the simulator
/// without an Apple Developer account / entitlement.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    /// The raw nonce for the in-flight sign-in. Apple receives only its
    /// SHA-256; the server re-hashes this to prove the identity token it gets
    /// belongs to this attempt and isn't a replay. Regenerated per attempt.
    @State private var currentNonce: String?

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
                let nonce = Self.randomNonce()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = Self.sha256(nonce)
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
            guard let nonce = currentNonce else {
                env.authStore.errorMessage = "Sign-in expired. Please try again."
                return
            }
            currentNonce = nil
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            Task { await env.authStore.signInWithApple(identityToken: token,
                                                       fullName: name.isEmpty ? nil : name,
                                                       nonce: nonce) }
        case .failure(let error):
            currentNonce = nil
            // User-cancelled (code 1001) is silent; surface anything else.
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                env.authStore.errorMessage = error.localizedDescription
            }
        }
    }

    /// 32 bytes from the system CSPRNG, hex-encoded. `SecRandomCopyBytes` is
    /// the only source used — a fallback to a weaker RNG would silently
    /// undermine the replay protection the nonce exists to provide.
    private static func randomNonce(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
