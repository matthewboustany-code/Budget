import Foundation
import WidgetKit
import BudgetModels

/// Publishes the numbers the widgets show into the shared App Group container.
///
/// Called after the dashboard's own refresh rather than on a timer: the app has
/// just parsed exactly these figures, so the widget never issues a request of
/// its own — no token in the extension, no second code path that can disagree
/// with the screen the user is looking at.
enum WidgetSnapshotWriter {
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSharing.appGroupID)
    }

    private static var fileURL: URL? {
        containerURL?.appendingPathComponent(WidgetSharing.snapshotFileName)
    }

    /// Writes the snapshot and asks WidgetKit to re-render — but only when
    /// something actually changed. WidgetKit budgets timeline reloads, so
    /// spending them on an identical refresh is how a widget ends up frozen
    /// later in the day when a number finally does move.
    static func publish(budget: BudgetStore, bills: BillsStore) {
        guard let fileURL else { return }   // no entitlement (or a preview) — nothing to do
        let snapshot = makeSnapshot(budget: budget, bills: bills)
        if let existing = read(), existing.matchesContent(of: snapshot) { return }
        do {
            try WidgetSharing.encoder().encode(snapshot).write(to: fileURL, options: .atomic)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // A widget that keeps yesterday's number is a far better outcome
            // than a crash in the app that feeds it.
            print("Widget snapshot write failed: \(error)")
        }
    }

    /// Signing out must not leave the household's balances on the Lock Screen.
    static func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func read() -> WidgetSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? WidgetSharing.decoder().decode(WidgetSnapshot.self, from: data)
    }

    private static func makeSnapshot(budget: BudgetStore, bills: BillsStore) -> WidgetSnapshot {
        // Budgeted categories only — the same rule as the dashboard card, where
        // unbudgeted spend is a caption rather than part of the total.
        let entries = budget.currentRollup?.budgetedEntries ?? []
        let limit = entries.reduce(Money(0)) { $0 + $1.budgeted + $1.rolloverIn }
        let spent = entries.reduce(Money(0)) { $0 + $1.spent }

        // The soonest bill still owed. A matched charge takes a bill off the
        // widget the same way it leaves the dashboard.
        let next = bills.bills
            .filter { $0.status != .paid }
            .min { $0.dueDate < $1.dueDate }

        return WidgetSnapshot(
            generatedAt: Date(),
            budgetedLimit: limit,
            budgetedSpent: spent,
            monthLabel: monthFormatter.string(from: Date()),
            nextBillName: next?.name,
            nextBillAmount: next?.amount,
            nextBillDueDate: next?.dueDate,
            nextBillIsOverdue: next?.status == .overdue)
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f
    }()
}

private extension WidgetSnapshot {
    /// Equality ignoring `generatedAt`, which moves on every refresh and would
    /// make every comparison report a change.
    func matchesContent(of other: WidgetSnapshot) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }
}
