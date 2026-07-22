import Vapor
import BudgetModels

/// Plaid linking: create a Link token for the app, exchange the returned public
/// token, and a dev-only sandbox path that links a test institution without the
/// Link UI (used for local testing and integration checks).
func registerPlaidRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let plaid = authed.grouped("plaid")

    // POST /v1/plaid/link-token
    plaid.post("link-token") { req async throws -> LinkTokenResponse in
        _ = try await req.requireMembership()
        let user = try req.requireUser()
        let config = req.appConfig
        let response = try await req.plaid.createLinkToken(
            clientUserId: user.id.uuidString, clientName: "Budget",
            products: config.plaidProducts, webhook: config.plaidWebhookURL)
        return LinkTokenResponse(linkToken: response.linkToken,
                                 expiration: response.expiration.flatMap(ISO8601DateFormatter().date(from:)))
    }

    // POST /v1/plaid/exchange — after Link succeeds on the device.
    plaid.post("exchange") { req async throws -> [Account] in
        let (household, member) = try await req.requireMembership()
        let body = try req.content.decode(ExchangePublicTokenRequest.self)
        return try await req.accountSync.linkPublicToken(
            body.publicToken, householdID: household.id, ownerMemberID: member.id,
            institutionName: body.institutionName, visibility: body.visibility)
    }

    // POST /v1/plaid/sandbox-link — dev-only: link a sandbox institution with no UI.
    plaid.post("sandbox-link") { req async throws -> [Account] in
        guard req.appConfig.authDevMode else {
            throw Abort(.forbidden, reason: "Sandbox link is only available in dev mode.")
        }
        let (household, member) = try await req.requireMembership()
        let body = (try? req.content.decode(SandboxLinkRequest.self)) ?? SandboxLinkRequest()
        let institution = body.institutionId ?? "ins_109508"  // First Platypus Bank (sandbox)
        let publicToken = try await req.plaid.sandboxCreatePublicToken(
            institutionId: institution, products: req.appConfig.plaidProducts)
        return try await req.accountSync.linkPublicToken(
            publicToken.publicToken, householdID: household.id, ownerMemberID: member.id,
            institutionName: body.institutionName ?? "Sandbox Bank", visibility: body.visibility)
    }

    // POST /v1/plaid/webhook — Plaid → server. P3 wires transaction updates;
    // acknowledge for now so Plaid stops retrying.
    routes.post("plaid", "webhook") { _ async -> HTTPStatus in .ok }
}
