import Vapor
import Foundation
import BudgetModels
import BudgetKit

/// Surfaces bills that are overdue or due within the next few days, per
/// household. Run by cron via `App bill-reminder` (see scripts/). For now it
/// logs — the personal deployment reads reminders off the server logs; APNs
/// push is the planned follow-up and slots in where the log line is emitted.
struct BillReminderCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "days", help: "How many days ahead to look (default 3).")
        var days: Int?
    }
    var help: String { "List bills overdue or due soon for every household." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let days = min(max(signature.days ?? 3, 1), 30)
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -14, to: today) ?? today
        let to = calendar.date(byAdding: .day, value: days, to: today) ?? today

        let households = try await HouseholdStore(db: app.appDatabase.dbPool).allHouseholds()
        let recurringStore = RecurringStore(db: app.appDatabase.dbPool)

        for household in households {
            // Reminders cover everything the household pays, so use the
            // unfiltered series list (this is an operator command, not a
            // member-scoped API response).
            let series = try await recurringStore.listAll(householdID: household.id)
            let bills = BillProjector.upcomingBills(series: series, from: from, to: to,
                                                    now: now, calendar: calendar)
            guard !bills.isEmpty else { continue }
            for bill in bills {
                let due = bill.dueDate.formatted(date: .abbreviated, time: .omitted)
                app.logger.info("Bill reminder [\(household.name)]: \(bill.name) \(bill.amount) due \(due) (\(bill.status))")
            }
        }
        app.logger.info("Bill reminders checked for \(households.count) household(s)")
    }
}
