import Foundation

/// One point on the net-worth-over-time series: assets and liabilities as of
/// a date, with `net` derived.
public struct NetWorthPoint: Codable, Sendable, Hashable, Identifiable {
    public var date: Date
    public var assets: Money
    public var liabilities: Money

    public var id: Date { date }
    /// Net worth = assets − liabilities (liabilities stored as a positive magnitude).
    public var net: Money { assets - liabilities }

    public init(date: Date, assets: Money, liabilities: Money) {
        self.date = date
        self.assets = assets
        self.liabilities = liabilities
    }
}

/// Income vs. expenses for one month.
public struct CashFlowSummary: Codable, Sendable, Hashable {
    public var month: Month
    public var income: Money
    public var expenses: Money

    public var net: Money { income - expenses }

    public init(month: Month, income: Money, expenses: Money) {
        self.month = month
        self.income = income
        self.expenses = expenses
    }
}

/// Spending in one category over a period, with its budget for comparison.
public struct SpendingByCategory: Codable, Sendable, Hashable, Identifiable {
    public var categoryID: UUID?
    public var categoryName: String
    public var amount: Money
    public var budgeted: Money?

    public var id: String { categoryID?.uuidString ?? "uncategorized" }

    public init(categoryID: UUID?, categoryName: String, amount: Money, budgeted: Money? = nil) {
        self.categoryID = categoryID
        self.categoryName = categoryName
        self.amount = amount
        self.budgeted = budgeted
    }
}
