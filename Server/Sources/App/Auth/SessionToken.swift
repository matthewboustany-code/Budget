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

    /// Sessions last 60 days. The app trades one for a fresh token via
    /// `POST /v1/auth/refresh` when fewer than 7 days remain; a token that
    /// does expire gets a 401, and the app signs out.
    static func issue(userID: UUID, lifetime: TimeInterval = 60 * 24 * 3600) -> SessionToken {
        SessionToken(userID: userID, expiresAt: Date().addingTimeInterval(lifetime))
    }
}
