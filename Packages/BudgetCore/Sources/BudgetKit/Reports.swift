import Foundation
import BudgetModels

/// Cash flow, spending, and net-worth rollups. Pure functions over model
/// arrays so both the app and the report endpoints share one definition.
public enum ReportCalculator {

    /// Income (inflows) vs. expenses (outflows) for a month. Transfers between
    /// the household's own accounts should be excluded by the caller; this
    /// function treats every transaction's sign at face value.
    public static func cashFlow(month: Month, transactions: [Transaction],
                                calendar: Calendar = .current) -> CashFlowSummary {
        let range = month.dateRange(calendar: calendar)   // computed once, not per tx
        var income: Money = 0
        var expenses: Money = 0
        for tx in transactions where range.contains(tx.date) {
            if tx.amount < 0 { income += -tx.amount }   // inflow
            else { expenses += tx.amount }              // outflow
        }
        return CashFlowSummary(month: month, income: income, expenses: expenses)
    }

    /// Spending grouped by category for a month, sorted highest-first, with
    /// each category's budget attached for comparison. Only outflows count.
    public static func spendingByCategory(month: Month, categories: [BudgetCategory],
                                          transactions: [Transaction],
                                          budgets: [Budget],
                                          calendar: Calendar = .current) -> [SpendingByCategory] {
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let budgetByCategory = Dictionary(
            budgets.filter { $0.month == month }.map { ($0.categoryID, $0.amount) },
            uniquingKeysWith: { a, _ in a })

        let range = month.dateRange(calendar: calendar)   // computed once, not per tx
        var totals: [UUID?: Money] = [:]
        for tx in transactions where range.contains(tx.date) {
            for part in BudgetCalculator.categoryAmounts(for: tx) where part.amount > 0 {
                totals[part.categoryID, default: 0] += part.amount
            }
        }

        return totals
            .map { categoryID, amount in
                SpendingByCategory(
                    categoryID: categoryID,
                    categoryName: categoryID.flatMap { names[$0] } ?? "Uncategorized",
                    amount: amount,
                    budgeted: categoryID.flatMap { budgetByCategory[$0] })
            }
            .sorted { $0.amount > $1.amount }
    }

    /// Current-instant net worth from the visible accounts.
    public static func netWorth(accounts: [Account]) -> NetWorthPoint {
        var assets: Money = 0
        var liabilities: Money = 0
        for account in accounts where !account.isHidden {
            if account.type.isLiability { liabilities += abs(account.currentBalance) }
            else { assets += account.currentBalance }
        }
        return NetWorthPoint(date: Date(), assets: assets, liabilities: liabilities)
    }

    /// A net-worth series from stored daily snapshots, sorted oldest-first.
    /// (Snapshots are produced server-side by `NetWorthSnapshotCommand`; this
    /// just normalizes/sorts them for charting.)
    public static func netWorthSeries(snapshots: [NetWorthPoint]) -> [NetWorthPoint] {
        snapshots.sorted { $0.date < $1.date }
    }
}
