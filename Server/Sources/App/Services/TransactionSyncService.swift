import Foundation
import GRDB
import Vapor
import BudgetModels

/// Pulls transactions for a Plaid item via `/transactions/sync`, upserting
/// added/modified and deleting removed, then advances the stored cursor.
/// New transactions are auto-categorized from Plaid's category.
struct TransactionSyncService {
    let db: DatabasePool
    let plaid: PlaidClient
    let cipher: TokenCipher

    /// Plaid dates are calendar days with no time. They're stored at 12:00
    /// UTC, not midnight: noon falls on the same calendar day in every zone
    /// within ±12 h, so a charge on the 1st never shows under the 31st in the
    /// US.
    private static let plaidDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH"
        return f
    }()

    static func plaidDate(_ day: String) -> Date? {
        plaidDateFormatter.date(from: day + "T12")
    }

    func sync(item: PlaidItemRecord) async throws {
        let token = try cipher.decrypt(item.accessTokenEncrypted)

        // Map Plaid account ids → our accounts, and category names → ids.
        let accounts = try await AccountStore(db: db).allAccounts(householdID: item.householdID)
        let accountByPlaid = Dictionary(accounts.compactMap { a in a.plaidAccountID.map { ($0, a) } },
                                        uniquingKeysWith: { first, _ in first })
        let categories = try await CategoryStore(db: db).list(householdID: item.householdID).categories
        let categoryIDByName = Dictionary(categories.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })

        var cursor = item.transactionsCursor
        var hasMore = true
        var pages = 0
        while hasMore && pages < 50 {
            let response = try await plaid.transactionsSync(accessToken: token, cursor: cursor)
            try await db.write { db in
                // Added before removed: a posted transaction arrives in `added`
                // with its pending predecessor in `removed`. Deleting first
                // would cascade away the pending row's comments and user edits,
                // so the posted one takes over the pending row in place instead.
                var repointed: Set<String> = []
                for pt in response.added + response.modified {
                    guard let account = accountByPlaid[pt.accountId] else { continue }
                    let tx = Self.map(pt, account: account, categoryIDByName: categoryIDByName)
                    if let pendingID = pt.pendingTransactionId,
                       try TransactionStore.repointPending(from: pendingID, to: tx, db) {
                        repointed.insert(pendingID)
                        continue
                    }
                    try TransactionStore.upsertPlaid(tx, db)
                }
                for removed in response.removed where !repointed.contains(removed.transactionId) {
                    try db.execute(sql: "DELETE FROM transactions WHERE plaid_transaction_id = ?",
                                   arguments: [removed.transactionId])
                }
            }
            cursor = response.nextCursor
            hasMore = response.hasMore
            pages += 1
        }
        if let cursor {
            try await PlaidItemStore(db: db).updateCursor(id: item.id, cursor: cursor)
        }

        // Fresh transactions can reveal (or advance) recurring series.
        try await RecurringService(db: db).refresh(householdID: item.householdID)
    }

    static func map(_ pt: PlaidTransaction, account: Account, categoryIDByName: [String: UUID]) -> Transaction {
        let categoryName = CategorySeeder.plaidCategoryName(
            primary: pt.personalFinanceCategory?.primary,
            detailed: pt.personalFinanceCategory?.detailed)
        return Transaction(
            id: UUID(),
            householdID: account.householdID,
            accountID: account.id,
            ownerMemberID: account.ownerMemberID,
            amount: AccountSyncService.decimal(pt.amount),
            date: plaidDate(pt.date) ?? Date(),
            name: pt.name,
            merchantName: pt.merchantName,
            categoryID: categoryName.flatMap { categoryIDByName[$0] },
            status: pt.pending ? .pending : .posted,
            visibility: account.visibility,   // inherit the account's default
            plaidTransactionID: pt.transactionId,
            createdAt: Date())
    }
}

extension Request {
    var transactionSync: TransactionSyncService {
        TransactionSyncService(db: appDatabase.dbPool, plaid: plaid,
                               cipher: TokenCipher(secret: appConfig.plaidTokenEncKey))
    }
}
