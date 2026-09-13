import Foundation

/// What the app hands its widgets through the shared App Group container.
///
/// A purpose-built snapshot rather than the widget re-reading `ResponseCache`
/// directly: the cache is keyed by full request URL, so a widget would have to
/// rebuild `?month=` and `?today=` exactly as the app does, and a key that
/// drifts by one character renders a blank widget with no error anywhere. This
/// carries only the numbers two small views need, written by the same code
/// that already parsed them.
public struct WidgetSnapshot: Codable, Sendable, Hashable {
    /// When the app last refreshed these numbers — the widget shows staleness
    /// rather than pretending a week-old figure is current.
    public var generatedAt: Date

    /// Budgeted amount + rollover across categories that actually have a
    /// budget, and what's been spent against them. Matches the dashboard's
    /// summary card, which also counts budgeted categories only.
    public var budgetedLimit: Money
    public var budgetedSpent: Money
    /// Localized month name for the budget widget's caption, e.g. "September".
    public var monthLabel: String

    public var nextBillName: String?
    public var nextBillAmount: Money?
    public var nextBillDueDate: Date?
    public var nextBillIsOverdue: Bool

    public init(generatedAt: Date, budgetedLimit: Money, budgetedSpent: Money, monthLabel: String,
                nextBillName: String? = nil, nextBillAmount: Money? = nil,
                nextBillDueDate: Date? = nil, nextBillIsOverdue: Bool = false) {
        self.generatedAt = generatedAt
        self.budgetedLimit = budgetedLimit
        self.budgetedSpent = budgetedSpent
        self.monthLabel = monthLabel
        self.nextBillName = nextBillName
        self.nextBillAmount = nextBillAmount
        self.nextBillDueDate = nextBillDueDate
        self.nextBillIsOverdue = nextBillIsOverdue
    }

    /// Negative when the household is over budget — the widget colors on this.
    public var remaining: Money { budgetedLimit - budgetedSpent }

    /// False when nothing is budgeted yet, so the widget can say so instead of
    /// showing a confident "$0 left".
    public var hasBudget: Bool { budgetedLimit > 0 }

    /// 0…1, for the progress ring. Guards the unbudgeted case, where the
    /// obvious `spent / limit` divides by zero.
    public var spentFraction: Double {
        guard budgetedLimit > 0 else { return budgetedSpent > 0 ? 1 : 0 }
        let value = (budgetedSpent as NSDecimalNumber).doubleValue
            / (budgetedLimit as NSDecimalNumber).doubleValue
        return min(max(value, 0), 1)
    }
}

/// Names shared by the app (writer) and the widget extension (reader). The
/// file IO itself lives on each side, because `containerURL(forSecurity…)` is
/// Darwin-only and this package also builds for Linux on the server.
public enum WidgetSharing {
    public static let appGroupID = "group.com.mbandhb.budget"
    public static let snapshotFileName = "widget-snapshot.json"

    /// One coder for both sides, so the date format can't disagree.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
