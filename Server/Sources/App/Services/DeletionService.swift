import Foundation
import GRDB
import Vapor
import BudgetModels

/// Disconnecting institutions and deleting accounts — the "right to delete"
/// half of the data model.
///
/// The ordering here is the whole point. Every local row hangs off `households`
/// or `users` with `ON DELETE CASCADE`, so the database side is one statement.
/// What cascades cannot do is tell **Plaid** to let go: the access token lives
/// in the row being deleted, so once it is gone the Item is unreachable and
/// Plaid keeps it — still connected to the user's bank, still billable —
/// indefinitely. So Plaid is always told first, and the local delete only
/// follows.
struct DeletionService {
    let db: DatabasePool
    let plaid: PlaidClient
    let cipher: TokenCipher
    let items: PlaidItemStore
    let households: HouseholdStore
    let logger: Logger

    init(db: DatabasePool, plaid: PlaidClient, cipher: TokenCipher, logger: Logger) {
        self.db = db
        self.plaid = plaid
        self.cipher = cipher
        self.items = PlaidItemStore(db: db)
        self.households = HouseholdStore(db: db)
        self.logger = logger
    }

    /// Disconnects one Item at Plaid, then deletes it locally along with its
    /// accounts and their transactions (both by cascade).
    func unlinkItem(_ item: PlaidItemRecord) async throws {
        await removeFromPlaid(item)
        try await items.delete(id: item.id)
    }

    /// Deletes a user: their linked institutions (disconnected at Plaid first),
    /// their membership, their device tokens, and — if they were the last member
    /// — the household and everything in it.
    ///
    /// A departing member does not take shared history with them. Their own
    /// accounts and transactions go, because those cascade from the Plaid items
    /// they owned, but the household's categories, budgets and goals belong to
    /// the household and remain for the partner still using it.
    func deleteUser(_ user: User) async throws {
        var householdToDelete: UUID?

        if let member = try await households.membership(userID: user.id) {
            for item in try await items.forMember(member.id) {
                await removeFromPlaid(item)
            }
            // Counted BEFORE the delete, since removing the user cascades the
            // membership row away and would make any later count misleading.
            let remaining = try await households.members(householdID: member.householdID)
            if remaining.count <= 1 { householdToDelete = member.householdID }
        }

        // Bound to a constant before the closure: capturing the `var` directly
        // is an error in Swift 6 language mode.
        let orphanedHousehold = householdToDelete
        let userID = user.id.uuidString
        try await db.write { db in
            // Cascades memberships (and through them plaid_items → accounts →
            // transactions) plus device_tokens.
            try db.execute(sql: "DELETE FROM users WHERE id = ?", arguments: [userID])
            if let householdID = orphanedHousehold {
                // Cascades everything household-scoped: categories, budgets,
                // goals, recurring series, net-worth snapshots, invites.
                try db.execute(sql: "DELETE FROM households WHERE id = ?",
                               arguments: [householdID.uuidString])
            }
        }
    }

    /// Best-effort by design. If Plaid rejects the removal — the Item was
    /// already removed, credentials are stale, Plaid is down — we log it and
    /// still delete locally. Refusing to delete someone's data because a third
    /// party is unavailable would be the wrong trade: the user asked for their
    /// data gone, and a stuck Item is recoverable from the Plaid dashboard.
    private func removeFromPlaid(_ item: PlaidItemRecord) async {
        do {
            let token = try cipher.decrypt(item.accessTokenEncrypted)
            try await plaid.removeItem(accessToken: token)
            logger.info("Removed Plaid item \(item.plaidItemID)")
        } catch {
            logger.error("""
                Could not remove Plaid item \(item.plaidItemID): \(error). \
                Deleting locally anyway — remove it from the Plaid dashboard \
                to stop billing for it.
                """)
        }
    }
}

extension Request {
    var deletion: DeletionService {
        DeletionService(db: appDatabase.dbPool, plaid: plaid,
                        cipher: TokenCipher(secret: appConfig.plaidTokenEncKey),
                        logger: logger)
    }
}
