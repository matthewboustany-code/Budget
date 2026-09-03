import Vapor
import Foundation
import BudgetModels
import BudgetKit

/// Surfaces bills that are overdue or due within the next few days, per
/// household. Run by cron via `App bill-reminder` (see scripts/).
///
/// Every due bill is logged, and when APNs is configured the household's
/// members are also pushed a single digest per run rather than one alert per
/// bill — five bills due on the same morning should be one notification, not
/// five. With APNs unconfigured the logging behaviour is unchanged, so this
/// command is safe to keep in cron either way.
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

        let householdStore = HouseholdStore(db: app.appDatabase.dbPool)
        let households = try await householdStore.allHouseholds()
        let recurringStore = RecurringStore(db: app.appDatabase.dbPool)
        let deviceStore = DeviceTokenStore(db: app.appDatabase.dbPool)
        let pushEnabled = app.appConfig.apnsConfigured

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

            guard pushEnabled else { continue }
            let members = try await householdStore.members(householdID: household.id)
            let tokens = try await deviceStore.tokens(userIDs: members.map(\.userID))
            guard !tokens.isEmpty else { continue }

            // Thread by household so a couple's reminders group together in
            // Notification Center instead of interleaving.
            await PushService.send(alert: Self.title(for: bills),
                                   body: Self.body(for: bills),
                                   threadID: "bills-\(household.id.uuidString)",
                                   to: tokens, on: app)
        }
        app.logger.info("Bill reminders checked for \(households.count) household(s)")
    }

    /// "1 bill due" reads better than a digest header when there's only one.
    static func title(for bills: [Bill]) -> String {
        let overdue = bills.filter { $0.status == .overdue }.count
        if overdue > 0 && overdue == bills.count {
            return overdue == 1 ? "1 bill overdue" : "\(overdue) bills overdue"
        }
        return bills.count == 1 ? "1 bill due soon" : "\(bills.count) bills due soon"
    }

    /// Names the bills when there are few enough to be useful, and falls back
    /// to a count so the alert can't grow unbounded.
    static func body(for bills: [Bill]) -> String {
        let names = bills.prefix(3).map(\.name)
        let remainder = bills.count - names.count
        let listed = names.joined(separator: ", ")
        return remainder > 0 ? "\(listed) and \(remainder) more" : listed
    }
}
