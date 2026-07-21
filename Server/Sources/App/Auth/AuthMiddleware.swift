import Foundation
import Vapor
import JWT
import BudgetModels

private struct AuthenticatedUserKey: StorageKey { typealias Value = User }

extension Request {
    /// The user resolved from the bearer token by `AuthMiddleware`, if any.
    var authenticatedUser: User? {
        get { storage[AuthenticatedUserKey.self] }
        set { storage[AuthenticatedUserKey.self] = newValue }
    }

    func requireUser() throws -> User {
        guard let user = authenticatedUser else {
            throw Abort(.unauthorized, reason: "Not signed in")
        }
        return user
    }
}

/// Verifies the `Authorization: Bearer <session JWT>` header, loads the user,
/// and attaches it to the request. Protected route groups are wrapped in this.
struct AuthMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let payload: SessionToken
        do {
            payload = try await req.jwt.verify(as: SessionToken.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired session")
        }
        guard let userID = payload.userID,
              let user = try await req.users.find(id: userID) else {
            throw Abort(.unauthorized, reason: "Unknown user")
        }
        req.authenticatedUser = user
        return try await next.respond(to: req)
    }
}
