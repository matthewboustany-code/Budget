import Foundation
import BudgetModels

/// Projects active recurring series into concrete upcoming `Bill` occurrences
/// for the bills calendar. Pure math shared by app and server. Occurrences are
/// never stored — they are recomputed from the series on every read, so a
/// series edit (toggle off, recategorize) is reflected immediately.
public enum BillProjector {

    /// Safety valve against runaway walks (a weekly series over a huge window).
    static let maxOccurrencesPerSeries = 60

    /// How far around a due date a posted charge may land and still count as
    /// that occurrence: a few days early (autopay pulls before the due date)
    /// and up to five days late (weekends, bank posting delays).
    public static let paidWindow = -3...5

    /// Bill occurrences due within `[from, to]`, sorted by due date. Only
    /// expense series project (income like paychecks stays out of the bills
    /// list; it still appears in the recurring list). An occurrence whose due
    /// date has passed without the series advancing is `.overdue`.
    /// `recentTransactions` are the caller-visible charges over (at least) the
    /// projected window widened by `paidWindow`; an occurrence matched by one
    /// of them comes back `.paid` instead of `.upcoming`/`.overdue`. Pass an
    /// empty array to skip payment matching entirely.
    public static func upcomingBills(series: [RecurringSeries],
                                     from: Date, to: Date,
                                     recentTransactions: [Transaction] = [],
                                     now: Date = Date(),
                                     calendar: Calendar = .current) -> [Bill] {
        let candidates = paymentCandidates(recentTransactions, calendar: calendar)
        return series
            .filter { $0.isActive && !$0.isIncome }
            .flatMap { occurrences(of: $0, from: from, to: to, now: now,
                                   calendar: calendar,
                                   payments: candidates[$0.merchantKey ?? ""] ?? []) }
            .sorted { $0.dueDate < $1.dueDate }
    }

    /// Expenses only, bucketed by normalized merchant and sorted by date, so
    /// each series' walk can consume them earliest-first. Refunds (negative
    /// amounts) never mark a bill paid.
    static func paymentCandidates(_ transactions: [Transaction],
                                  calendar: Calendar) -> [String: [Date]] {
        var buckets: [String: [Date]] = [:]
        for tx in transactions where tx.amount > 0 {
            let key = RecurringDetector.normalize(tx.merchantName ?? tx.name)
            guard !key.isEmpty else { continue }
            buckets[key, default: []].append(calendar.startOfDay(for: tx.date))
        }
        return buckets.mapValues { $0.sorted() }
    }

    static func occurrences(of series: RecurringSeries,
                            from: Date, to: Date, now: Date,
                            calendar: Calendar,
                            payments: [Date] = []) -> [Bill] {
        let (settled, pending) = occurrenceDates(of: series, from: from, to: to,
                                                 calendar: calendar)
        // Each charge pays at most one occurrence, claimed in due-date order so
        // one payment can't satisfy two neighbouring months of a monthly bill.
        var unclaimed = payments
        let todayStart = calendar.startOfDay(for: now)
        var bills: [Bill] = []
        // `settled` dates are behind `nextDate`: detection only advances past an
        // occurrence once its charge posted, so an unmatched one is history
        // rather than an overdue bill and is dropped instead of invented.
        for due in settled {
            guard let claimed = claimIndex(for: due, in: unclaimed, calendar: calendar) else { continue }
            unclaimed.remove(at: claimed)
            bills.append(bill(for: series, due: due, status: .paid))
        }
        for due in pending {
            let claimed = claimIndex(for: due, in: unclaimed, calendar: calendar)
            if let claimed { unclaimed.remove(at: claimed) }
            bills.append(bill(for: series, due: due,
                              status: claimed != nil ? .paid
                                  : (due < todayStart ? .overdue : .upcoming)))
        }
        return bills
    }

    private static func bill(for series: RecurringSeries, due: Date,
                             status: BillStatus) -> Bill {
        Bill(id: UUID(),
             householdID: series.householdID,
             recurringSeriesID: series.id,
             name: series.name,
             amount: series.averageAmount,
             dueDate: due,
             status: status,
             categoryID: series.categoryID)
    }

    /// Due dates in `[from, to]`, ascending, split into those *behind*
    /// `nextDate` (`settled` — shown only when a charge claims them) and those
    /// from `nextDate` onward (`pending`). The backwards walk exists because
    /// detection advances `nextDate` as soon as a charge posts: without it the
    /// occurrence that was just paid would vanish instead of showing `.paid`.
    static func occurrenceDates(of series: RecurringSeries,
                                from: Date, to: Date,
                                calendar: Calendar) -> (settled: [Date], pending: [Date]) {
        guard let next = series.nextDate, series.cadence != .irregular else { return ([], []) }
        var past: [Date] = []
        var cursor = next
        var steps = 0
        while cursor > from, steps < maxOccurrencesPerSeries {
            guard let previous = previousOccurrence(before: cursor, cadence: series.cadence,
                                                    calendar: calendar) else { break }
            cursor = previous
            steps += 1
            if cursor >= from && cursor <= to { past.append(cursor) }
        }

        var future: [Date] = []
        var due = next
        steps = 0
        while due <= to && steps < maxOccurrencesPerSeries {
            if due >= from { future.append(due) }
            guard let step = nextOccurrence(after: due, cadence: series.cadence,
                                            calendar: calendar) else { break }
            due = step
            steps += 1
        }
        return (past.reversed(), future)
    }

    /// The earliest charge within `paidWindow` days of `due`, if any.
    static func claimIndex(for due: Date, in payments: [Date],
                           calendar: Calendar) -> Int? {
        let dueDay = calendar.startOfDay(for: due)
        return payments.firstIndex { day in
            guard let offset = calendar.dateComponents([.day], from: dueDay, to: day).day
            else { return false }
            return paidWindow.contains(offset)
        }
    }

    /// Calendar-aware stepping: monthly cadences land on the same day-of-month
    /// (clamped by `Calendar` for short months) instead of drifting by a fixed
    /// day count. Public so detection predicts `nextDate` the same way.
    public static func nextOccurrence(after date: Date, cadence: RecurringCadence,
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

    /// The mirror of `nextOccurrence`, used only to reach back into the
    /// look-back window.
    static func previousOccurrence(before date: Date, cadence: RecurringCadence,
                                   calendar: Calendar) -> Date? {
        switch cadence {
        case .weekly: return calendar.date(byAdding: .day, value: -7, to: date)
        case .biweekly: return calendar.date(byAdding: .day, value: -14, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: -1, to: date)
        case .quarterly: return calendar.date(byAdding: .month, value: -3, to: date)
        case .yearly: return calendar.date(byAdding: .year, value: -1, to: date)
        case .irregular: return nil
        }
    }
}
