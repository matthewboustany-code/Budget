import Foundation
import BudgetModels

/// Budget-vs-actual math, shared verbatim between the app (for instant local
/// rollups) and the server (for authoritative report endpoints). Keeping one
/// implementation is why `BudgetKit` exists — the app and server can never
/// disagree about what "spent" means.
public enum BudgetCalculator {

    /// Effective category assignments for a transaction, honoring splits.
    /// Returns (categoryID, signed amount) pairs. Outflow stays positive.
    static func categoryAmounts(for tx: Transaction) -> [(categoryID: UUID?, amount: Money)] {
        if tx.isSplit {
            return tx.splits.map { ($0.categoryID, $0.amount) }
        }
        return [(tx.categoryID, tx.amount)]
    }

    /// Total outflow (spending) assigned to a category within a month.
    /// Inflows/refunds (negative amounts) reduce the total, so a refund in the
    /// same category nets against spending, as users expect.
    public static func spent(in categoryID: UUID, month: Month,
                             transactions: [Transaction],
                             calendar: Calendar = .current) -> Money {
        var total: Money = 0
        for tx in transactions where month.contains(tx.date, calendar: calendar) {
            for part in categoryAmounts(for: tx) where part.categoryID == categoryID {
                total += part.amount
            }
        }
        return total
    }

    /// Budget progress for one category in one month, resolving rollover by
    /// walking backward through prior months while rollover stays enabled.
    /// `budgetsByCategoryMonth` is keyed by `"<categoryID>|<YYYY-MM>"`.
    public static func progress(categoryID: UUID, month: Month,
                                transactions: [Transaction],
                                budgetsByCategoryMonth: [String: Budget],
                                calendar: Calendar = .current) -> BudgetProgress {
        let key = Self.key(categoryID, month)
        let budget = budgetsByCategoryMonth[key]
        let budgeted = budget?.amount ?? 0
        let rolloverIn = budget?.rolloverEnabled == true
            ? rollover(into: month, categoryID: categoryID,
                       transactions: transactions,
                       budgetsByCategoryMonth: budgetsByCategoryMonth,
                       calendar: calendar)
            : 0
        let spentThisMonth = spent(in: categoryID, month: month,
                                   transactions: transactions, calendar: calendar)
        return BudgetProgress(categoryID: categoryID, month: month,
                              budgeted: budgeted, rolloverIn: rolloverIn,
                              spent: spentThisMonth)
    }

    /// Available balance rolled into `month` from the immediately prior month,
    /// recursively (prior rollover feeds the next). Stops at the first month
    /// with no budget or rollover disabled to bound the walk.
    private static func rollover(into month: Month, categoryID: UUID,
                                 transactions: [Transaction],
                                 budgetsByCategoryMonth: [String: Budget],
                                 calendar: Calendar) -> Money {
        let prev = month.previous
        guard let prevBudget = budgetsByCategoryMonth[key(categoryID, prev)],
              prevBudget.rolloverEnabled else { return 0 }
        let prevRolloverIn = rollover(into: prev, categoryID: categoryID,
                                      transactions: transactions,
                                      budgetsByCategoryMonth: budgetsByCategoryMonth,
                                      calendar: calendar)
        let prevSpent = spent(in: categoryID, month: prev,
                              transactions: transactions, calendar: calendar)
        // Carry whatever was left (may be negative if overspent).
        return prevBudget.amount + prevRolloverIn - prevSpent
    }

    /// Full month rollup across all categories that have either a budget or
    /// spending. Categories with neither are omitted.
    public static func monthBudget(month: Month, categories: [BudgetCategory],
                                   transactions: [Transaction],
                                   budgets: [Budget],
                                   calendar: Calendar = .current) -> MonthBudget {
        let byKey = Dictionary(budgets.map { (key($0.categoryID, $0.month), $0) },
                               uniquingKeysWith: { a, _ in a })
        let entries = categories.compactMap { category -> BudgetProgress? in
            let p = progress(categoryID: category.id, month: month,
                             transactions: transactions,
                             budgetsByCategoryMonth: byKey, calendar: calendar)
            return (p.budgeted == 0 && p.spent == 0 && p.rolloverIn == 0) ? nil : p
        }
        return MonthBudget(month: month, entries: entries)
    }

    static func key(_ categoryID: UUID, _ month: Month) -> String {
        "\(categoryID.uuidString)|\(month)"
    }
}

/// Validates that a transaction's split amounts sum to its total.
public func splitsBalance(_ tx: Transaction) -> Bool {
    guard tx.isSplit else { return true }
    return tx.splits.reduce(Money(0)) { $0 + $1.amount } == tx.amount
}
