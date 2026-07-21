import Foundation

/// A named grouping of categories (e.g. "Essentials", "Lifestyle", "Income").
public struct CategoryGroup: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var name: String
    /// Income groups are excluded from spending budgets and drive the income
    /// side of cash flow.
    public var isIncome: Bool
    public var sortOrder: Int

    public init(id: UUID, householdID: UUID, name: String, isIncome: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.isIncome = isIncome
        self.sortOrder = sortOrder
    }
}

/// A spending (or income) category transactions are assigned to.
/// Named `BudgetCategory` to avoid colliding with the Objective-C runtime's
/// `Category` typedef that Foundation exposes on Apple platforms.
public struct BudgetCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var groupID: UUID
    public var name: String
    /// SF Symbol name, e.g. "cart".
    public var icon: String?
    /// Hex color like "#22C55E".
    public var colorHex: String?
    public var sortOrder: Int
    public var isArchived: Bool

    public init(id: UUID, householdID: UUID, groupID: UUID, name: String,
                icon: String? = nil, colorHex: String? = nil,
                sortOrder: Int = 0, isArchived: Bool = false) {
        self.id = id
        self.householdID = householdID
        self.groupID = groupID
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}

/// A monthly budget target for one category. Monarch-style flexible budget:
/// a limit to track spending against, with optional rollover of the unused
/// (or overspent) remainder into the next month.
public struct Budget: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var categoryID: UUID
    public var month: Month
    public var amount: Money
    public var rolloverEnabled: Bool

    public init(id: UUID, householdID: UUID, categoryID: UUID, month: Month,
                amount: Money, rolloverEnabled: Bool = false) {
        self.id = id
        self.householdID = householdID
        self.categoryID = categoryID
        self.month = month
        self.amount = amount
        self.rolloverEnabled = rolloverEnabled
    }
}

/// Computed budget-vs-actual for one category in one month. Produced by
/// `BudgetKit.budgetProgress` and returned to the app; not stored.
public struct BudgetProgress: Codable, Sendable, Hashable, Identifiable {
    public var categoryID: UUID
    public var month: Month
    /// This month's set limit.
    public var budgeted: Money
    /// Rollover carried in from prior months (0 when rollover disabled).
    public var rolloverIn: Money
    /// Total outflow assigned to the category this month.
    public var spent: Money

    public var id: UUID { categoryID }

    public init(categoryID: UUID, month: Month, budgeted: Money,
                rolloverIn: Money = 0, spent: Money) {
        self.categoryID = categoryID
        self.month = month
        self.budgeted = budgeted
        self.rolloverIn = rolloverIn
        self.spent = spent
    }

    /// Available = budgeted + rolled-in − spent. Negative means overspent.
    public var available: Money { budgeted + rolloverIn - spent }
    public var isOverspent: Bool { available < 0 }
    /// 0...1+ fraction of the (budgeted + rolled-in) limit consumed.
    public var fractionSpent: Double {
        let limit = budgeted + rolloverIn
        guard limit > 0 else { return spent > 0 ? 1 : 0 }
        return (spent as NSDecimalNumber).doubleValue / (limit as NSDecimalNumber).doubleValue
    }
}

/// A whole month's budget rollup, the payload behind the Budget screen.
public struct MonthBudget: Codable, Sendable, Hashable {
    public var month: Month
    public var entries: [BudgetProgress]

    public init(month: Month, entries: [BudgetProgress]) {
        self.month = month
        self.entries = entries
    }

    public var totalBudgeted: Money { entries.reduce(0) { $0 + $1.budgeted + $1.rolloverIn } }
    public var totalSpent: Money { entries.reduce(0) { $0 + $1.spent } }
    public var totalAvailable: Money { entries.reduce(0) { $0 + $1.available } }
}
