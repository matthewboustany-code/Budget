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
        // In production without a redirect URI, OAuth institutions — which is
        // most large US banks — will fail while small ones succeed. Say so once
        // per attempt rather than leaving it to be diagnosed from Link's UI.
        if config.plaidEnv == "production" && config.plaidRedirectURI == nil {
            req.logger.warning("""
                PLAID_REDIRECT_URI is unset in production: OAuth institutions \
                (Chase, Wells Fargo, Capital One, …) will fail to link.
                """)
        }
        let response = try await req.plaid.createLinkToken(
            clientUserId: user.id.uuidString, clientName: "Budget",
            products: config.plaidProducts, webhook: config.plaidWebhookURL,
            redirectUri: config.plaidRedirectURI)
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

    // GET /v1/plaid/items — the caller's linked institutions, for the
    // disconnect UI. Scoped to what they own: you can only unlink your own.
    plaid.get("items") { req async throws -> [LinkedInstitution] in
        let (_, member) = try await req.requireMembership()
        return try await req.plaidItems.forMember(member.id).map(\.linked)
    }

    // POST /v1/plaid/sync — "Sync now": pull every connection the caller owns
    // instead of waiting for a webhook or the nightly cron. Each sync is
    // several Plaid calls, so it's limited per user; the limiter sits inside
    // AuthMiddleware so it keys by user rather than by IP.
    authed.grouped(RateLimitMiddleware(rule: .init(limit: 6, window: 60 * 60), name: "plaid-sync"))
        .post("plaid", "sync") { req async throws -> [LinkedInstitution] in
            let (_, member) = try await req.requireMembership()
            for item in try await req.plaidItems.forMember(member.id) {
                do {
                    try await req.accountSync.refreshBalances(item: item)
                    try await req.transactionSync.sync(item: item)
                } catch {
                    // One broken bank mustn't stop the others; its status
                    // (set by the sync) is what the app shows.
                    req.logger.error("Sync now failed for item \(item.plaidItemID): \(error)")
                }
            }
            return try await req.plaidItems.forMember(member.id).map(\.linked)
        }

    // POST /v1/plaid/items/:id/update-link-token — a Link token in update
    // mode, to repair an item whose login expired. Owner-only.
    plaid.post("items", ":id", "update-link-token") { req async throws -> LinkTokenResponse in
        let (_, member) = try await req.requireMembership()
        let user = try req.requireUser()
        let item = try await ownedItem(req, member: member)
        let config = req.appConfig
        let accessToken = try TokenCipher(secret: config.plaidTokenEncKey).decrypt(item.accessTokenEncrypted)
        let response = try await req.plaid.createLinkToken(
            clientUserId: user.id.uuidString, clientName: "Budget",
            products: config.plaidProducts, webhook: config.plaidWebhookURL,
            redirectUri: config.plaidRedirectURI, accessToken: accessToken)
        return LinkTokenResponse(linkToken: response.linkToken,
                                 expiration: response.expiration.flatMap(ISO8601DateFormatter().date(from:)))
    }

    // POST /v1/plaid/items/:id/sync — right after a reconnect: refresh
    // balances and pull transactions now. Success clears the item's error, so
    // "Needs attention" goes away without waiting for the next webhook.
    plaid.post("items", ":id", "sync") { req async throws -> LinkedInstitution in
        let (_, member) = try await req.requireMembership()
        let item = try await ownedItem(req, member: member)
        try await req.accountSync.refreshBalances(item: item)
        try await req.transactionSync.sync(item: item)
        guard let fresh = try await req.plaidItems.find(id: item.id) else {
            throw Abort(.notFound, reason: "Connection not found")
        }
        return fresh.linked
    }

    // DELETE /v1/plaid/items/:id — disconnect one institution. Removes the Item
    // at Plaid first, then deletes it locally along with its accounts and
    // transactions.
    plaid.delete("items", ":id") { req async throws -> HTTPStatus in
        let (_, member) = try await req.requireMembership()
        guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }) else {
            throw Abort(.badRequest, reason: "Invalid item id")
        }
        // Owner-only, and a 404 rather than a 403 so this can't be used to
        // probe for items belonging to anyone else.
        guard let item = try await req.plaidItems.find(id: id),
              item.ownerMemberID == member.id else {
            throw Abort(.notFound, reason: "Connection not found")
        }
        try await req.deletion.unlinkItem(item)
        return .noContent
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

    // POST /v1/plaid/webhook — Plaid → server. The Plaid-Verification JWT is
    // checked first (signature, freshness, exact body digest), so only Plaid
    // can trigger a sync. Dev mode skips verification: local/sandbox tests
    // post unsigned bodies, and the handler's only power is syncing items we
    // already hold.
    routes.post("plaid", "webhook") { req async throws -> HTTPStatus in
        let rawBody = req.body.data.map { Data(buffer: $0) } ?? Data()
        if !req.appConfig.authDevMode {
            guard let token = req.headers.first(name: "Plaid-Verification") else {
                throw Abort(.unauthorized, reason: "Missing Plaid-Verification header")
            }
            do {
                try await PlaidWebhookVerifier(plaid: req.plaid).verify(token: token, rawBody: rawBody)
            } catch {
                req.logger.warning("Plaid webhook rejected: \(error)")
                throw Abort(.unauthorized, reason: "Webhook verification failed")
            }
        }
        struct Webhook: Content {
            struct PlaidWebhookError: Content { var error_code: String? }
            var webhook_type: String?
            var webhook_code: String?
            var item_id: String?
            var error: PlaidWebhookError?
        }
        guard let hook = try? req.content.decode(Webhook.self), let itemID = hook.item_id,
              let item = try? await req.plaidItems.find(plaidItemID: itemID) else { return .ok }

        // ITEM webhooks report connection health, not new data: record it so
        // the app can ask the owner to reconnect.
        if hook.webhook_type == "ITEM" {
            switch hook.webhook_code {
            case "ERROR":
                try await req.plaidItems.markProblem(id: item.id, status: .error,
                                                     errorCode: hook.error?.error_code)
            case "PENDING_EXPIRATION", "PENDING_DISCONNECT":
                try await req.plaidItems.markProblem(id: item.id, status: .pendingExpiration, errorCode: nil)
            case "USER_PERMISSION_REVOKED", "USER_ACCOUNT_REVOKED":
                try await req.plaidItems.markProblem(id: item.id, status: .revoked, errorCode: nil)
            case "LOGIN_REPAIRED":
                try await req.plaidItems.markHealthy(id: item.id)
            default:
                break
            }
            return .ok
        }

        do {
            try await req.transactionSync.sync(item: item)
        } catch {
            // Still 200: a non-2xx makes Plaid retry a sync that will fail
            // the same way. The sync marks item-level failures on the item;
            // the log is how anything else gets noticed.
            req.logger.error("Webhook sync failed for item \(item.plaidItemID): \(error)")
        }
        return .ok
    }
}

/// The caller's own item named by `:id`, or 404 — never 403, so a route
/// can't be used to probe for items belonging to anyone else.
private func ownedItem(_ req: Request, member: HouseholdMember) async throws -> PlaidItemRecord {
    guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }),
          let item = try await req.plaidItems.find(id: id),
          item.ownerMemberID == member.id else {
        throw Abort(.notFound, reason: "Connection not found")
    }
    return item
}

extension PlaidItemRecord {
    /// The app-facing view of this connection, health included.
    var linked: LinkedInstitution {
        LinkedInstitution(id: id, institutionName: institutionName, status: status,
                          errorCode: errorCode, lastSyncedAt: lastSyncedAt)
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
