import Foundation

/// Currency amounts are represented as `Decimal` to avoid binary
/// floating-point rounding error on money. Convention throughout the app:
/// a **positive** transaction amount is an **outflow** (spending), a
/// **negative** amount is an **inflow** (income) — matching Plaid's sign
/// convention so we never have to flip signs on ingest.
public typealias Money = Decimal

/// Visibility of an account or transaction within a household.
/// `shared` items are visible to every member; `private` items are visible
/// only to the owning member (the Honeydue "hide from partner" model).
public enum Visibility: String, Codable, Sendable, Hashable, CaseIterable {
    case shared
    case `private`
}

/// The kind of financial account, mapped from Plaid's account type/subtype.
public enum AccountType: String, Codable, Sendable, Hashable, CaseIterable {
    case checking
    case savings
    case creditCard
    case investment
    case loan
    case cash
    case other

    /// Assets add to net worth; liabilities subtract from it.
    public var isLiability: Bool {
        switch self {
        case .creditCard, .loan: return true
        case .checking, .savings, .investment, .cash, .other: return false
        }
    }
}

/// Posting state of a transaction.
public enum TransactionStatus: String, Codable, Sendable, Hashable {
    case pending
    case posted
}

/// Lifecycle of a bill occurrence.
public enum BillStatus: String, Codable, Sendable, Hashable {
    case upcoming
    case paid
    case overdue
    case skipped
}

/// How often a recurring series repeats.
public enum RecurringCadence: String, Codable, Sendable, Hashable, CaseIterable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case yearly
    case irregular

    /// Nominal number of days between occurrences, used by the recurring
    /// detector and the upcoming-bills projection.
    public var approximateDays: Int {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        case .quarterly: return 91
        case .yearly: return 365
        case .irregular: return 0
        }
    }
}

/// Role of a member within a household.
public enum MemberRole: String, Codable, Sendable, Hashable {
    case owner
    case member
}

/// A calendar month, the unit budgets are keyed by. Encoded as `"YYYY-MM"`
/// so it is stable across time zones and human-readable on the wire.
public struct Month: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    /// 1...12
    public let month: Int

    public init(year: Int, month: Int) {
        precondition((1...12).contains(month), "month must be 1...12")
        self.year = year
        self.month = month
    }

    public var description: String { String(format: "%04d-%02d", year, month) }

    /// Parses `"YYYY-MM"`. Returns nil on malformed input.
    public init?(_ string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]),
              (1...12).contains(m) else { return nil }
        self.init(year: y, month: m)
    }

    public var next: Month {
        month == 12 ? Month(year: year + 1, month: 1) : Month(year: year, month: month + 1)
    }

    public var previous: Month {
        month == 1 ? Month(year: year - 1, month: 12) : Month(year: year, month: month - 1)
    }

    public static func < (lhs: Month, rhs: Month) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    // Encoded as the "YYYY-MM" string form.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Month(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Invalid Month string: \(raw)"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
