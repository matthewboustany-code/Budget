import Foundation
import BudgetModels

/// Conversions between Swift values and their SQLite TEXT storage form. Money is
/// stored as an exact `Decimal` string and dates as ISO8601 — matching the JSON
/// wire format so values look identical in the DB and on the API.
enum DBFormat {
    private static let dateFormatter = ISO8601DateFormatter()

    static func string(_ date: Date) -> String { dateFormatter.string(from: date) }
    static func date(_ text: String?) -> Date? { text.flatMap { dateFormatter.date(from: $0) } }

    static func string(_ money: Money) -> String { NSDecimalNumber(decimal: money).stringValue }
    static func money(_ text: String?) -> Money { (text.flatMap { Decimal(string: $0) }) ?? 0 }

    static func string(_ id: UUID) -> String { id.uuidString }
    static func uuid(_ text: String?) -> UUID? { text.flatMap { UUID(uuidString: $0) } }
}
