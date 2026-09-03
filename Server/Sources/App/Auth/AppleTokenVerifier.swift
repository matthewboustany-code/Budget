import Foundation
import Vapor
import JWT
import Crypto

/// The identity we extract from a verified Apple sign-in.
struct VerifiedAppleIdentity: Sendable {
    let subject: String   // stable, opaque Apple user id (the token `sub`)
    let email: String?
}

enum AppleAuthError: Error {
    case missingNonce
    case nonceMismatch
}

/// Verifies a real Apple identity token against Apple's public keys (fetched by
/// the JWT package from Apple's JWKS) and checks the audience is our app.
///
/// Signature and audience alone don't make a token safe to accept: an identity
/// token intercepted from another session would still verify. The nonce binds
/// the token to *this* sign-in attempt — the app generates a random value,
/// sends Apple its SHA-256, and Apple echoes that hash into the `nonce` claim.
/// Re-hashing the raw nonce the app sent us and comparing is what closes the
/// replay hole, so a token arriving without one is rejected outright.
struct LiveAppleTokenVerifier {
    let bundleID: String

    func verify(idToken: String, rawNonce: String?, on req: Request) async throws -> VerifiedAppleIdentity {
        let token = try await req.jwt.apple.verify(idToken, applicationIdentifier: bundleID)

        guard let rawNonce, !rawNonce.isEmpty else {
            throw AppleAuthError.missingNonce
        }
        guard Self.nonceMatches(rawNonce: rawNonce, claim: token.nonce) else {
            throw AppleAuthError.nonceMismatch
        }

        return VerifiedAppleIdentity(subject: token.subject.value, email: token.email)
    }

    /// True when `claim` is the hex SHA-256 of `rawNonce`. Split out from
    /// `verify` so it can be tested without a live Apple token.
    static func nonceMatches(rawNonce: String, claim: String?) -> Bool {
        let expected = SHA256.hash(data: Data(rawNonce.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        // Constant-time compare: equal-length hex digests, so a byte-by-byte
        // OR leaks nothing through timing.
        guard let claim, claim.count == expected.count else { return false }
        return zip(claim.utf8, expected.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0
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
