import Foundation
import Vapor
import JWT

/// Our own session bearer token, signed with the server's HMAC secret. Issued
/// after a successful Sign in with Apple and sent on every subsequent request.
struct SessionToken: JWTPayload {
    /// Subject = our user's UUID (string).
    var sub: SubjectClaim
    /// Expiration.
    var exp: ExpirationClaim

    init(userID: UUID, expiresAt: Date) {
        self.sub = .init(value: userID.uuidString)
        self.exp = .init(value: expiresAt)
    }

    func verify(using algorithm: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }

    var userID: UUID? { UUID(uuidString: sub.value) }

    /// Sessions last 60 days; the app silently refreshes by re-authing when a
    /// request 401s.
    static func issue(userID: UUID, lifetime: TimeInterval = 60 * 24 * 3600) -> SessionToken {
        SessionToken(userID: userID, expiresAt: Date().addingTimeInterval(lifetime))
    }
}
