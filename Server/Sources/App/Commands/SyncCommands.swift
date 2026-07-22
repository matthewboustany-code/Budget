import Vapor
import BudgetModels
import BudgetKit

/// Nightly balance refresh for every linked Plaid item, followed by a net-worth
/// snapshot. Run by cron via `App sync-all` (the non-webhook safety net).
struct SyncAllItemsCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Refresh balances for all linked Plaid items, then snapshot net worth." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let items = try await PlaidItemStore(db: app.appDatabase.dbPool).all()
        let service = AccountSyncService(
            db: app.appDatabase.dbPool, plaid: app.plaid,
            cipher: TokenCipher(secret: app.appConfig.plaidTokenEncKey))

        for item in items {
            do {
                try await service.refreshBalances(item: item)
            } catch {
                app.logger.error("Balance sync failed for item \(item.plaidItemID): \(error)")
            }
        }
        app.logger.info("Refreshed \(items.count) Plaid item(s)")
        try await NetWorthSnapshotCommand.snapshotAll(app)
    }
}

/// Records today's net worth for every household (assets/liabilities from all
/// non-hidden accounts). Idempotent per day. Run by cron via `App networth-snapshot`.
struct NetWorthSnapshotCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Record today's net worth for every household." }

    func run(using context: CommandContext, signature: Signature) async throws {
        try await Self.snapshotAll(context.application)
    }

    static func snapshotAll(_ app: Application) async throws {
        let households = try await HouseholdStore(db: app.appDatabase.dbPool).allHouseholds()
        let accountStore = AccountStore(db: app.appDatabase.dbPool)
        let store = NetWorthStore(db: app.appDatabase.dbPool)
        let today = Calendar.current.startOfDay(for: Date())

        for household in households {
            let accounts = try await accountStore.allAccounts(householdID: household.id)
                .filter { !$0.isHidden }
            let computed = ReportCalculator.netWorth(accounts: accounts)
            let point = NetWorthPoint(date: today, assets: computed.assets, liabilities: computed.liabilities)
            try await store.snapshot(householdID: household.id, point: point)
        }
        app.logger.info("Snapshotted net worth for \(households.count) household(s)")
    }
}
