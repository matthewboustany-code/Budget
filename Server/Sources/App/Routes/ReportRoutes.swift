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

    // GET /v1/reports/cashflow?months=6 — oldest first, ending this month.
    reports.get("cashflow") { req async throws -> CashFlowReportResponse in
        let (household, member) = try await req.requireMembership()
        let monthCount = min(max(req.query[Int.self, at: "months"] ?? 6, 1), 24)

        async let allTransactions = req.transactions.allVisible(householdID: household.id,
                                                                memberID: member.id)
        let transferIDs = try await req.categories.transferCategoryIDs(householdID: household.id)
        let transactions = try await allTransactions.filter {
            $0.categoryID.map { !transferIDs.contains($0) } ?? true
        }

        var months: [Month] = []
        var month = Month(date: Date())
        for _ in 0..<monthCount {
            months.append(month)
            month = month.previous
        }
        let summaries = months.reversed().map {
            ReportCalculator.cashFlow(month: $0, transactions: transactions)
        }
        return CashFlowReportResponse(months: Array(summaries))
    }

    // GET /v1/reports/spending?month=YYYY-MM (defaults to the current month)
    reports.get("spending") { req async throws -> SpendingReportResponse in
        let (household, member) = try await req.requireMembership()
        let month: Month
        if let raw = req.query[String.self, at: "month"] {
            guard let parsed = Month(raw) else {
                throw Abort(.badRequest, reason: "month must look like 2026-07")
            }
            month = parsed
        } else {
            month = Month(date: Date())
        }

        async let transactions = req.transactions.allVisible(householdID: household.id,
                                                             memberID: member.id)
        async let tree = req.categories.list(householdID: household.id)
        async let budgets = req.budgets.listAll(householdID: household.id)
        let transferIDs = try await req.categories.transferCategoryIDs(householdID: household.id)

        let entries = ReportCalculator.spendingByCategory(
            month: month, categories: try await tree.categories,
            transactions: try await transactions, budgets: try await budgets)
            .filter { $0.categoryID.map { !transferIDs.contains($0) } ?? true }
        let total = entries.reduce(Money(0)) { $0 + $1.amount }
        return SpendingReportResponse(month: month, entries: entries, total: total)
    }
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
