import Foundation

/// A detected or user-created repeating charge (subscriptions, utilities,
/// paychecks). Drives the upcoming-bills projection and reminders.
public struct RecurringSeries: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var name: String
    public var categoryID: UUID?
    /// Typical amount per occurrence (positive = a bill, negative = income).
    public var averageAmount: Money
    public var cadence: RecurringCadence
    /// Account the series is usually drawn from, if consistent.
    public var accountID: UUID?
    public var lastDate: Date?
    public var nextDate: Date?
    public var isActive: Bool

    public init(id: UUID, householdID: UUID, name: String, categoryID: UUID? = nil,
                averageAmount: Money, cadence: RecurringCadence, accountID: UUID? = nil,
                lastDate: Date? = nil, nextDate: Date? = nil, isActive: Bool = true) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.categoryID = categoryID
        self.averageAmount = averageAmount
        self.cadence = cadence
        self.accountID = accountID
        self.lastDate = lastDate
        self.nextDate = nextDate
        self.isActive = isActive
    }

    public var isIncome: Bool { averageAmount < 0 }
}

/// A single upcoming (or past) occurrence of a bill, shown on the calendar.
public struct Bill: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var recurringSeriesID: UUID?
    public var name: String
    public var amount: Money
    public var dueDate: Date
    public var status: BillStatus
    public var categoryID: UUID?
    public var note: String?

    public init(id: UUID, householdID: UUID, recurringSeriesID: UUID? = nil,
                name: String, amount: Money, dueDate: Date,
                status: BillStatus = .upcoming, categoryID: UUID? = nil, note: String? = nil) {
        self.id = id
        self.householdID = householdID
        self.recurringSeriesID = recurringSeriesID
        self.name = name
        self.amount = amount
        self.dueDate = dueDate
        self.status = status
        self.categoryID = categoryID
        self.note = note
    }
}

/// A shared savings goal (vacation, emergency fund, down payment).
public struct Goal: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var name: String
    public var targetAmount: Money
    public var currentAmount: Money
    public var targetDate: Date?
    public var icon: String?
    public var colorHex: String?
    public var createdAt: Date

    public init(id: UUID, householdID: UUID, name: String, targetAmount: Money,
                currentAmount: Money = 0, targetDate: Date? = nil, icon: String? = nil,
                colorHex: String? = nil, createdAt: Date) {
        self.id = id
        self.householdID = householdID
        self.name = name
        self.targetAmount = targetAmount
        self.currentAmount = currentAmount
        self.targetDate = targetDate
        self.icon = icon
        self.colorHex = colorHex
        self.createdAt = createdAt
    }

    /// 0...1 progress toward the target (clamped).
    public var progress: Double {
        guard targetAmount > 0 else { return 0 }
        let frac = (currentAmount as NSDecimalNumber).doubleValue
            / (targetAmount as NSDecimalNumber).doubleValue
        return min(max(frac, 0), 1)
    }

    public var isComplete: Bool { currentAmount >= targetAmount }
    public var remaining: Money { max(targetAmount - currentAmount, 0) }
}

/// A contribution toward a goal, optionally attributed to a member.
public struct GoalContribution: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var goalID: UUID
    public var amount: Money
    public var date: Date
    public var memberID: UUID?
    public var note: String?

    public init(id: UUID, goalID: UUID, amount: Money, date: Date,
                memberID: UUID? = nil, note: String? = nil) {
        self.id = id
        self.goalID = goalID
        self.amount = amount
        self.date = date
        self.memberID = memberID
        self.note = note
    }
}
