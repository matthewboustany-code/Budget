import Vapor
import Foundation
import BudgetModels
import BudgetKit

/// Cash flow and spending reports. Like every read, totals are computed over
/// only the transactions the caller can see, so partners may get different
/// numbers when private activity exists. Transactions categorized as
/// "Transfer" are excluded from both reports — moving money between the
/// household's own accounts (credit-card payments, savings sweeps) is neither
/// income nor spending. Recategorizing a payment to Transfer is how the user
/// removes a double-count, mirroring Monarch.
func registerReportRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let reports = authed.grouped("reports")

    // GET /v1/reports/cashflow?months=6&end=YYYY-MM — oldest first, ending at
    // `end`. The app passes its own current month: the server's clock is UTC,
    // so its "this month" flips hours early for a US user on month end.
    reports.get("cashflow") { req async throws -> CashFlowReportResponse in
        let (household, member) = try await req.requireMembership()
        let monthCount = min(max(req.query[Int.self, at: "months"] ?? 6, 1), 24)
        let end = try monthQuery(req, "end") ?? Month(date: Date())

        var months: [Month] = []
        var month = end
        for _ in 0..<monthCount {
            months.append(month)
            month = month.previous
        }

        // Only the months being reported.
        async let allTransactions = req.transactions.allVisible(
            householdID: household.id, memberID: member.id,
            from: months.last?.startDate(), to: end.endDate())
        let transferIDs = try await req.categories.transferCategoryIDs(householdID: household.id)
        let transactions = try await allTransactions.filter {
            $0.categoryID.map { !transferIDs.contains($0) } ?? true
        }
        let summaries = months.reversed().map {
            ReportCalculator.cashFlow(month: $0, transactions: transactions)
        }
        return CashFlowReportResponse(months: Array(summaries))
    }

    // GET /v1/reports/spending?month=YYYY-MM (defaults to the current month)
    reports.get("spending") { req async throws -> SpendingReportResponse in
        let (household, member) = try await req.requireMembership()
        let month = try monthQuery(req, "month") ?? Month(date: Date())

        async let transactions = req.transactions.allVisible(householdID: household.id,
                                                             memberID: member.id,
                                                             from: month.startDate(), to: month.endDate())
        // Archived categories too, or their past spend shows as "Uncategorized".
        async let categories = req.categories.listIncludingArchived(householdID: household.id)
        async let budgets = req.budgets.listAll(householdID: household.id)
        let transferIDs = try await req.categories.transferCategoryIDs(householdID: household.id)

        let entries = ReportCalculator.spendingByCategory(
            month: month, categories: try await categories,
            transactions: try await transactions, budgets: try await budgets)
            .filter { $0.categoryID.map { !transferIDs.contains($0) } ?? true }
        let total = entries.reduce(Money(0)) { $0 + $1.amount }
        return SpendingReportResponse(month: month, entries: entries, total: total)
    }
}

/// Parses an optional `YYYY-MM` query parameter; nil when absent, 400 when malformed.
private func monthQuery(_ req: Request, _ name: String) throws -> Month? {
    guard let raw = req.query[String.self, at: name] else { return nil }
    guard let month = Month(raw) else {
        throw Abort(.badRequest, reason: "\(name) must look like 2026-07")
    }
    return month
}

extension CategoryStore {
    /// IDs of the household's "Transfer" categories (seeded under Other;
    /// matched by name so a user-created duplicate behaves the same way).
    func transferCategoryIDs(householdID: UUID) async throws -> Set<UUID> {
        Set(try await list(householdID: householdID).categories
            .filter { $0.name.caseInsensitiveCompare("Transfer") == .orderedSame }
            .map(\.id))
    }
}
