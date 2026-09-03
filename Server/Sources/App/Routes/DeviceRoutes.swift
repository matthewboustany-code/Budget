import Vapor
import Foundation
import BudgetModels

/// Device registration for APNs bill reminders.
///
/// Tokens are per-user, not per-household: a reminder goes to the people in
/// the household, and each of them may have several devices. Registration is
/// idempotent because the app re-registers on every launch — APNs reissues
/// tokens freely, and the client can't tell a new one from a repeat.
func registerDeviceRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let devices = authed.grouped("devices")

    // POST /v1/devices
    devices.post { req async throws -> HTTPStatus in
        let user = try req.requireUser()
        let body = try req.content.decode(RegisterDeviceRequest.self)
        let token = body.token.trimmingCharacters(in: .whitespaces)
        // APNs tokens are hex; reject anything else rather than storing junk
        // we'd retry against Apple forever.
        guard !token.isEmpty, token.count <= 200,
              token.allSatisfy({ $0.isHexDigit }) else {
            throw Abort(.badRequest, reason: "Not a valid device token.")
        }
        let environment = body.environment == "production" ? "production" : "sandbox"
        try await req.deviceTokens.register(token: token, userID: user.id, environment: environment)
        return .noContent
    }

    // DELETE /v1/devices/:token — called on sign-out so a shared device stops
    // receiving the previous user's reminders.
    devices.delete(":token") { req async throws -> HTTPStatus in
        _ = try req.requireUser()
        guard let token = req.parameters.get("token") else {
            throw Abort(.badRequest, reason: "Missing token.")
        }
        try await req.deviceTokens.unregister(token: token)
        return .noContent
    }
}
