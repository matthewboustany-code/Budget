import Foundation
import BudgetModels

/// Heuristic detection of recurring charges from transaction history. Groups
/// by a normalized merchant name, then infers a cadence from the median gap
/// between occurrences. Deliberately conservative — better to miss a series
/// than to invent one; the user can always confirm.
public enum RecurringDetector {

    /// Minimum occurrences before we call something recurring.
    public static let minimumOccurrences = 3

    public static func detect(transactions: [Transaction],
                              householdID: UUID,
                              calendar: Calendar = .current,
                              now: Date = Date()) -> [RecurringSeries] {
        let groups = Dictionary(grouping: transactions) { normalize($0.merchantName ?? $0.name) }

        return groups.compactMap { key, txs -> RecurringSeries? in
            guard key.isEmpty == false, txs.count >= minimumOccurrences else { return nil }
            let sorted = txs.sorted { $0.date < $1.date }
            let gaps = zip(sorted, sorted.dropFirst()).map {
                calendar.dateComponents([.day], from: $0.date, to: $1.date).day ?? 0
            }
            guard let medianGap = median(gaps.filter { $0 > 0 }), medianGap > 0 else { return nil }
            let cadence = cadence(forDayGap: medianGap)
            guard cadence != .irregular else { return nil }

            let amounts = sorted.map { $0.amount }
            let avg = amounts.reduce(Money(0), +) / Money(amounts.count)
            // Reject series whose amounts swing wildly (not a stable
            // subscription) or mix inflows and outflows (a charge/refund
            // pattern — Plaid's sandbox "United Airlines" +500/−500 pair
            // averages to a nonsense $0 bill).
            guard amountsAreStable(amounts), avg != 0,
                  amounts.allSatisfy({ ($0 > 0) == (avg > 0) }) else { return nil }

            let last = sorted.last!.date
            let next = calendar.date(byAdding: .day, value: cadence.approximateDays, to: last)

            return RecurringSeries(
                id: UUID(),
                householdID: householdID,
                name: sorted.last?.merchantName ?? sorted.last?.name ?? key,
                categoryID: sorted.last?.categoryID,
                averageAmount: avg,
                cadence: cadence,
                accountID: mostCommonAccount(sorted),
                lastDate: last,
                nextDate: next,
                isActive: (next.map { $0 >= calendar.date(byAdding: .day, value: -cadence.approximateDays, to: now) ?? now } ?? false))
        }
        .sorted { ($0.nextDate ?? .distantFuture) < ($1.nextDate ?? .distantFuture) }
    }

    /// Lowercase, strip trailing digits/store numbers and punctuation so
    /// "NETFLIX #123" and "Netflix" collapse to one merchant. Public because
    /// it is also the stable key the server uses to match freshly detected
    /// series against stored ones across refreshes.
    public static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let stripped = lowered.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(stripped))
            .split(separator: " ")
            .prefix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func cadence(forDayGap gap: Int) -> RecurringCadence {
        switch gap {
        case 5...9: return .weekly
        case 12...16: return .biweekly
        case 25...35: return .monthly
        case 80...100: return .quarterly
        case 350...380: return .yearly
        default: return .irregular
        }
    }

    static func amountsAreStable(_ amounts: [Money]) -> Bool {
        guard let first = amounts.first else { return false }
        let base = abs((first as NSDecimalNumber).doubleValue)
        guard base > 0 else { return false }
        let values = amounts.map { abs(($0 as NSDecimalNumber).doubleValue) }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return false }
        let maxDeviation = values.map { abs($0 - mean) / mean }.max() ?? 0
        return maxDeviation <= 0.25   // within 25% of the mean
    }

    static func median(_ values: [Int]) -> Int? {
        guard values.isEmpty == false else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func mostCommonAccount(_ txs: [Transaction]) -> UUID? {
        let counts = Dictionary(grouping: txs, by: { $0.accountID }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key
    }
}
