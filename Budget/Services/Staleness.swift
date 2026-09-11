import Foundation

/// A store that remembers when it last loaded from the server, so screens
/// refresh when data is old instead of only when it's empty. "Empty" stopped
/// meaning "never loaded" once stores prefill from `ResponseCache`: a tab
/// would show cached data forever. Only a successful network load sets
/// `lastLoaded`, so cache-prefilled data always counts as stale.
@MainActor
protocol StaleAware: AnyObject {
    var lastLoaded: Date? { get }
}

extension StaleAware {
    func isStale(after interval: TimeInterval = 5 * 60) -> Bool {
        guard let lastLoaded else { return true }
        return Date().timeIntervalSince(lastLoaded) > interval
    }
}

extension AccountStore: StaleAware {}
extension TransactionStore: StaleAware {}
extension BudgetStore: StaleAware {}
extension ReportsStore: StaleAware {}
extension BillsStore: StaleAware {}
extension GoalsStore: StaleAware {}
extension CategoryStore: StaleAware {}
