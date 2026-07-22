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

    // PATCH /v1/accounts/:id — rename, change visibility, hide (owner only).
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
        try await req.accounts.update(id: id, name: body.name,
                                      visibility: body.visibility, isHidden: body.isHidden)
        return try await req.accounts.get(id: id) ?? account
    }

    // GET /v1/networth — current point (from visible accounts) + snapshot series.
    authed.get("networth") { req async throws -> NetWorthResponse in
        let (household, member) = try await req.requireMembership()
        let visible = try await req.accounts.visibleAccounts(householdID: household.id, memberID: member.id)
        let current = ReportCalculator.netWorth(accounts: visible)
        let series = try await req.networth.series(householdID: household.id)
        return NetWorthResponse(current: current, series: series)
    }
}
