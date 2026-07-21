import Foundation
import Vapor
import JWT

/// The identity we extract from a verified Apple sign-in.
struct VerifiedAppleIdentity: Sendable {
    let subject: String   // stable, opaque Apple user id (the token `sub`)
    let email: String?
}

/// Verifies a real Apple identity token against Apple's public keys (fetched by
/// the JWT package from Apple's JWKS) and checks the audience is our app.
struct LiveAppleTokenVerifier {
    let bundleID: String

    func verify(idToken: String, on req: Request) async throws -> VerifiedAppleIdentity {
        let token = try await req.jwt.apple.verify(idToken, applicationIdentifier: bundleID)
        return VerifiedAppleIdentity(subject: token.subject.value, email: token.email)
    }
}

/// Dev/test verifier used when `AUTH_DEV_MODE` is on. Treats the "token" as
/// `dev:<name>` (or a bare name) and derives a stable subject + email, so the
/// full auth + household flow works on the simulator and in tests without an
/// Apple Developer account. Never used in production.
struct DevAppleTokenVerifier {
    func verify(idToken: String) -> VerifiedAppleIdentity {
        let raw = idToken.hasPrefix("dev:") ? String(idToken.dropFirst(4)) : idToken
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty ?? "dev-user"
        return VerifiedAppleIdentity(subject: "dev-\(name)", email: "\(name)@dev.local")
    }
}
