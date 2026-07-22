import Vapor
import BudgetModels
import BudgetKit

/// Monthly category budgets (Monarch-style). Reading returns the stored
/// budgets plus the computed budget-vs-actual rollup from `BudgetKit` — the
/// same math the app runs locally, so both always agree. Spent totals only
/// include transactions the caller can see, mirroring the transactions list.
func registerBudgetRoutes(_ routes: RoutesBuilder) {
    let authed = routes.grouped(AuthMiddleware())
    let budgets = authed.grouped("budgets")

    // GET /v1/budgets?month=YYYY-MM (defaults to the current month)
    budgets.get { req async throws -> BudgetMonthResponse in
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

        async let allBudgets = req.budgets.listAll(householdID: household.id)
        async let tree = req.categories.list(householdID: household.id)
        async let transactions = req.transactions.allVisible(householdID: household.id,
                                                             memberID: member.id)

        // Income groups are excluded from spending budgets (they feed the cash
        // flow reports instead).
        let categories = try await tree.spendingCategories
        let rollup = BudgetCalculator.monthBudget(month: month, categories: categories,
                                                  transactions: try await transactions,
                                                  budgets: try await allBudgets)
        let monthBudgets = try await allBudgets.filter { $0.month == month }
        return BudgetMonthResponse(month: month, budgets: monthBudgets, rollup: rollup)
    }

    // PUT /v1/budgets/:categoryID — upsert one category's budget for a month.
    budgets.put(":categoryID") { req async throws -> Budget in
        let (household, _) = try await req.requireMembership()
        guard let categoryID = req.parameters.get("categoryID").flatMap({ UUID(uuidString: $0) }) else {
            throw Abort(.badRequest, reason: "Invalid category id")
        }
        let body = try req.content.decode(SetBudgetRequest.self)
        guard body.amount >= 0 else {
            throw Abort(.badRequest, reason: "Budget amount can't be negative.")
        }
        guard let category = try await req.categories.get(id: categoryID),
              category.householdID == household.id, !category.isArchived else {
            throw Abort(.notFound, reason: "Category not found")
        }
        if let group = try await req.categories.getGroup(id: category.groupID), group.isIncome {
            throw Abort(.badRequest, reason: "Income categories can't be budgeted.")
        }
        return try await req.budgets.upsert(householdID: household.id, categoryID: categoryID,
                                            month: body.month, amount: body.amount,
                                            rolloverEnabled: body.rolloverEnabled)
    }
}

extension CategoriesResponse {
    /// Categories eligible for a spending budget (everything outside income groups).
    var spendingCategories: [BudgetCategory] {
        let incomeGroupIDs = Set(groups.filter(\.isIncome).map(\.id))
        return categories.filter { !incomeGroupIDs.contains($0.groupID) }
    }
}
