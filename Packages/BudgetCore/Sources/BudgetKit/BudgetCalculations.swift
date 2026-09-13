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
        // Resolve the month's bounds once — `month.contains` would otherwise
        // recompute the range (two Calendar conversions) for every transaction,
        // and this loop runs once per category per rollover level.
        let range = month.dateRange(calendar: calendar)
        var total: Money = 0
        for tx in transactions where range.contains(tx.date) {
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
    ///
    /// Same results as calling `progress` per category, without its cost:
    /// that path rescans every transaction once per category per rollover
    /// level (~4M comparisons for 20 categories × 36 months × 6k rows). Here
    /// spend is bucketed by (category, month) in one pass, and each month's
    /// rollover is computed once per category.
    public static func monthBudget(month: Month, categories: [BudgetCategory],
                                   transactions: [Transaction],
                                   budgets: [Budget],
                                   calendar: Calendar = .current) -> MonthBudget {
        let byKey = Dictionary(budgets.map { (key($0.categoryID, $0.month), $0) },
                               uniquingKeysWith: { a, _ in a })
        let spentByKey = spentBuckets(transactions, calendar: calendar)
        let entries = categories.compactMap { category -> BudgetProgress? in
            let budget = byKey[key(category.id, month)]
            let rolloverIn = budget?.rolloverEnabled == true
                ? bucketedRollover(into: month, categoryID: category.id,
                                   budgets: byKey, spent: spentByKey)
                : 0
            let p = BudgetProgress(categoryID: category.id, month: month,
                                   budgeted: budget?.amount ?? 0, rolloverIn: rolloverIn,
                                   spent: spentByKey[key(category.id, month)] ?? 0)
            return (p.budgeted == 0 && p.spent == 0 && p.rolloverIn == 0) ? nil : p
        }
        return MonthBudget(month: month, entries: entries)
    }

    /// Spend per `"<categoryID>|<YYYY-MM>"` in a single pass, honoring splits.
    /// Uncategorized amounts are dropped — no budget can own them.
    static func spentBuckets(_ transactions: [Transaction], calendar: Calendar) -> [String: Money] {
        var buckets: [String: Money] = [:]
        for tx in transactions {
            let month = Month(date: tx.date, calendar: calendar)
            for part in categoryAmounts(for: tx) {
                guard let categoryID = part.categoryID else { continue }
                buckets[key(categoryID, month), default: 0] += part.amount
            }
        }
        return buckets
    }

    /// `rollover(into:)` over the buckets. Walks back to the start of the
    /// rollover chain once, then carries forward — linear in chain length,
    /// where the recursive version re-scanned transactions at every level.
    private static func bucketedRollover(into month: Month, categoryID: UUID,
                                         budgets: [String: Budget],
                                         spent: [String: Money]) -> Money {
        var chain: [(budget: Budget, month: Month)] = []
        var cursor = month.previous
        while let budget = budgets[key(categoryID, cursor)], budget.rolloverEnabled {
            chain.append((budget, cursor))
            cursor = cursor.previous
        }
        var carried: Money = 0
        for (budget, m) in chain.reversed() {
            carried = budget.amount + carried - (spent[key(categoryID, m)] ?? 0)
        }
        return carried
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
