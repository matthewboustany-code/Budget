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

    private static let plaidDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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
                for pt in response.added + response.modified {
                    guard let account = accountByPlaid[pt.accountId] else { continue }
                    let tx = Self.map(pt, account: account, categoryIDByName: categoryIDByName)
                    try TransactionStore.upsertPlaid(tx, db)
                }
                for removed in response.removed {
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
            date: plaidDateFormatter.date(from: pt.date) ?? Date(),
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
