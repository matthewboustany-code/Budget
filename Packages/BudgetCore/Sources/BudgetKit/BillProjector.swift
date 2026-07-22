import Foundation
import BudgetModels

/// Projects active recurring series into concrete upcoming `Bill` occurrences
/// for the bills calendar. Pure math shared by app and server. Occurrences are
/// never stored — they are recomputed from the series on every read, so a
/// series edit (toggle off, recategorize) is reflected immediately.
public enum BillProjector {

    /// Safety valve against runaway walks (a weekly series over a huge window).
    static let maxOccurrencesPerSeries = 60

    /// Bill occurrences due within `[from, to]`, sorted by due date. Only
    /// expense series project (income like paychecks stays out of the bills
    /// list; it still appears in the recurring list). An occurrence whose due
    /// date has passed without the series advancing is `.overdue`.
    public static func upcomingBills(series: [RecurringSeries],
                                     from: Date, to: Date,
                                     now: Date = Date(),
                                     calendar: Calendar = .current) -> [Bill] {
        series
            .filter { $0.isActive && !$0.isIncome }
            .flatMap { occurrences(of: $0, from: from, to: to, now: now, calendar: calendar) }
            .sorted { $0.dueDate < $1.dueDate }
    }

    static func occurrences(of series: RecurringSeries,
                            from: Date, to: Date, now: Date,
                            calendar: Calendar) -> [Bill] {
        guard var due = series.nextDate, series.cadence != .irregular else { return [] }
        var bills: [Bill] = []
        var steps = 0
        while due <= to && steps < maxOccurrencesPerSeries {
            if due >= from {
                bills.append(Bill(
                    id: UUID(),
                    householdID: series.householdID,
                    recurringSeriesID: series.id,
                    name: series.name,
                    amount: series.averageAmount,
                    dueDate: due,
                    status: due < calendar.startOfDay(for: now) ? .overdue : .upcoming,
                    categoryID: series.categoryID))
            }
            guard let next = nextOccurrence(after: due, cadence: series.cadence, calendar: calendar) else { break }
            due = next
            steps += 1
        }
        return bills
    }

    /// Calendar-aware stepping: monthly cadences land on the same day-of-month
    /// (clamped by `Calendar` for short months) instead of drifting by a fixed
    /// day count.
    static func nextOccurrence(after date: Date, cadence: RecurringCadence,
                               calendar: Calendar) -> Date? {
        switch cadence {
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly: return calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: return calendar.date(byAdding: .month, value: 3, to: date)
        case .yearly: return calendar.date(byAdding: .year, value: 1, to: date)
        case .irregular: return nil
        }
    }
}
