import Foundation
import BudgetModels

extension Month {
    /// The month a date falls in, using the given calendar's time zone.
    public init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1)
    }

    /// First instant of this month.
    public func startDate(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    /// First instant of the following month (exclusive upper bound).
    public func endDate(calendar: Calendar = .current) -> Date {
        next.startDate(calendar: calendar)
    }

    /// Half-open `[start, end)` range covering the whole month.
    public func dateRange(calendar: Calendar = .current) -> Range<Date> {
        startDate(calendar: calendar)..<endDate(calendar: calendar)
    }

    /// Whether a date lies within this month.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        dateRange(calendar: calendar).contains(date)
    }
}
