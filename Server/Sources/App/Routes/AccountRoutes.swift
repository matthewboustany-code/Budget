import Vapor
import BudgetModels
import BudgetKit

/// Accounts list/edit and net worth. Every route is scoped to the caller's
/// household and honors per-account visibility.
func registerAccountRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())

    // GET /v1/accounts — the member's visible accounts.
    authed.get("accounts") { req async throws -> [Account] in
        let (household, member) = try await req.requireMembership()
        return try await req.accounts.visibleAccounts(householdID: household.id, memberID: member.id)
    }

    // POST /v1/accounts — a manual account (cash, a bank Plaid doesn't
    // support, a loan to a friend). Plaid accounts only come from linking.
    authed.post("accounts") { req async throws -> Account in
        let (household, member) = try await req.requireMembership()
        var body = try req.content.decode(CreateManualAccountRequest.self)
        body.name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.name.isEmpty else { throw Abort(.badRequest, reason: "Name can't be empty.") }
        return try await req.accounts.createManual(householdID: household.id, ownerMemberID: member.id, body)
    }

    // PATCH /v1/accounts/:id — rename, change visibility, hide (owner only).
    // `currentBalance` is accepted for manual accounts only.
    authed.patch("accounts", ":id") { req async throws -> Account in
        let (_, member) = try await req.requireMembership()
        guard let id = req.parameters.get("id").flatMap({ UUID(uuidString: $0) }) else {
            throw Abort(.badRequest, reason: "Invalid account id")
        }
        guard let account = try await req.accounts.get(id: id) else {
            throw Abort(.notFound, reason: "Account not found")
        }
        guard account.ownerMemberID == member.id else {
            throw Abort(.forbidden, reason: "Only the account owner can change it.")
        }
        let body = try req.content.decode(UpdateAccountRequest.self)
        if body.currentBalance != nil && !account.isManual {
            throw Abort(.badRequest, reason: "A linked account's balance comes from the bank.")
        }
        try await req.accounts.update(id: id, name: body.name,
                                      visibility: body.visibility, isHidden: body.isHidden,
                                      currentBalance: body.currentBalance)
        return try await req.accounts.get(id: id) ?? account
    }

    // GET /v1/networth — current point (from visible accounts) + snapshot series.
    authed.get("networth") { req async throws -> NetWorthResponse in
        let (household, member) = try await req.requireMembership()
        let visible = try await req.accounts.visibleAccounts(householdID: household.id, memberID: member.id)
        let current = ReportCalculator.netWorth(accounts: visible)
        let series = try await req.networth.series(householdID: household.id, memberID: member.id)
        return NetWorthResponse(current: current, series: series)
    }
}
