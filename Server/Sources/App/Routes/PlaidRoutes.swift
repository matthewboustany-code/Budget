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
        let accounts = try await req.accountSync.linkPublicToken(
            body.publicToken, householdID: household.id, ownerMemberID: member.id,
            institutionName: body.institutionName, visibility: body.visibility)
        await initialTransactionSync(req, householdID: household.id)
        return accounts
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
        let accounts = try await req.accountSync.linkPublicToken(
            publicToken.publicToken, householdID: household.id, ownerMemberID: member.id,
            institutionName: body.institutionName ?? "Sandbox Bank", visibility: body.visibility)
        await initialTransactionSync(req, householdID: household.id)
        return accounts
    }

    // POST /v1/plaid/webhook — Plaid → server. On a transactions update, sync the
    // item. (Signature verification is deferred to P7 hardening.)
    routes.post("plaid", "webhook") { req async -> HTTPStatus in
        struct Webhook: Content { var webhook_type: String?; var item_id: String? }
        guard let hook = try? req.content.decode(Webhook.self), let itemID = hook.item_id else { return .ok }
        if let item = try? await PlaidItemStore(db: req.appDatabase.dbPool).find(plaidItemID: itemID) {
            try? await req.transactionSync.sync(item: item)
        }
        return .ok
    }
}

/// Initial (best-effort) transaction pull after linking. Failures (e.g. Plaid
/// PRODUCT_NOT_READY) are swallowed — the webhook and nightly command catch up.
private func initialTransactionSync(_ req: Request, householdID: UUID) async {
    guard let items = try? await PlaidItemStore(db: req.appDatabase.dbPool).forHousehold(householdID) else { return }
    for item in items {
        try? await req.transactionSync.sync(item: item)
    }
}
