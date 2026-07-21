import Vapor
import JWT
import BudgetModels

/// `POST /v1/auth/apple` — the only unauthenticated data route. Verifies the
/// Apple identity token (or a dev token when `AUTH_DEV_MODE` is on), upserts the
/// user, and returns a session bearer token plus any existing household.
func registerAuthRoutes(_ routes: RoutesBuilder) {
    routes.post("auth", "apple") { req async throws -> AuthResponse in
        let body = try req.content.decode(AppleSignInRequest.self)
        let config = req.appConfig

        let identity: VerifiedAppleIdentity
        if config.authDevMode {
            identity = DevAppleTokenVerifier().verify(idToken: body.identityToken)
        } else {
            identity = try await LiveAppleTokenVerifier(bundleID: config.appleBundleID)
                .verify(idToken: body.identityToken, on: req)
        }

        let displayName = body.fullName?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? identity.email?.components(separatedBy: "@").first
            ?? "Me"

        let user = try await req.users.findOrCreate(
            appleUserID: identity.subject, email: identity.email, displayName: displayName)

        let token = try await req.jwt.sign(SessionToken.issue(userID: user.id))

        // Include household context so the app can skip onboarding if they're
        // already set up.
        let member = try await req.households.membership(userID: user.id)
        var household: Household?
        if let member { household = try await req.households.household(id: member.householdID) }

        return AuthResponse(token: token, user: user, household: household, member: member)
    }
}
