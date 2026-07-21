import Foundation
import Observation
import BudgetModels

/// Handles Sign in with Apple: sends the identity token to the server and
/// applies the returned session to `Session`.
@MainActor
@Observable
final class AuthStore {
    private let api: APIClient
    private let session: Session

    var isWorking = false
    var errorMessage: String?

    init(api: APIClient, session: Session) {
        self.api = api
        self.session = session
    }

    func signInWithApple(identityToken: String, fullName: String?) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let response: AuthResponse = try await api.post(
                "v1/auth/apple",
                body: AppleSignInRequest(identityToken: identityToken, fullName: fullName))
            session.apply(response)
        } catch {
            errorMessage = (error as? APIClientError)?.errorDescription ?? error.localizedDescription
        }
    }

    #if DEBUG
    /// Dev sign-in for exercising the flow without an Apple Developer account
    /// (the server must have AUTH_DEV_MODE on). Two names → two distinct users,
    /// so the couples flow can be tested on one machine.
    func devSignIn(as name: String) async {
        await signInWithApple(identityToken: "dev:\(name.lowercased())", fullName: name)
    }
    #endif
}
