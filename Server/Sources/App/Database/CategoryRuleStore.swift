import Foundation
import GRDB
import Vapor
import BudgetModels
import BudgetKit

/// Household category rules ("always file NETFLIX under Entertainment") and
/// the bulk recategorization that creating one performs. Rules are consulted
/// by `TransactionSyncService` before Plaid's category.
struct CategoryRuleStore {
    let db: DatabasePool

    /// The rule key for a transaction — the same normalization recurring
    /// detection uses, so "NETFLIX #123" and "Netflix" share a rule.
    static func merchantKey(merchantName: String?, name: String) -> String {
        RecurringDetector.normalize(merchantName ?? name)
    }

    func list(householdID: UUID) async throws -> [CategoryRule] {
        try await db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM category_rules WHERE household_id = ? ORDER BY merchant_key",
                             arguments: [householdID.uuidString]).map(CategoryRule.init(row:))
        }
    }

    /// Merchant key → category, for the sync.
    func categoryByKey(householdID: UUID) async throws -> [String: UUID] {
        Dictionary(try await list(householdID: householdID).map { ($0.merchantKey, $0.categoryID) },
                   uniquingKeysWith: { first, _ in first })
    }

    func householdID(ofRule id: UUID) async throws -> UUID? {
        try await db.read { db in
            try String.fetchOne(db, sql: "SELECT household_id FROM category_rules WHERE id = ?",
                                arguments: [id.uuidString]).flatMap(UUID.init(uuidString:))
        }
    }

    func delete(id: UUID) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM category_rules WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// How many transactions other than `excluded` a rule for `key` would recategorize.
    func matchCount(householdID: UUID, memberID: UUID, key: String, excluding excluded: UUID) async throws -> Int {
        try await db.read { db in
            try Self.matchingIDs(db, householdID: householdID, memberID: memberID, key: key)
                .filter { $0 != excluded.uuidString }.count
        }
    }

    /// Creates the rule for `key` (or repoints an existing one) and files every
    /// matching transaction under it, in one write transaction.
    func apply(householdID: UUID, memberID: UUID, key: String, categoryID: UUID) async throws -> CreateCategoryRuleResponse {
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO category_rules (id, household_id, merchant_key, category_id, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(household_id, merchant_key) DO UPDATE SET category_id = excluded.category_id
                """, arguments: [UUID().uuidString, householdID.uuidString, key, categoryID.uuidString,
                                 DBFormat.string(Date())])
            guard let rule = try Row.fetchOne(db, sql: "SELECT * FROM category_rules WHERE household_id = ? AND merchant_key = ?",
                                              arguments: [householdID.uuidString, key]).map(CategoryRule.init(row:)) else {
                throw Abort(.internalServerError, reason: "Rule was not saved")
            }
            let ids = try Self.matchingIDs(db, householdID: householdID, memberID: memberID, key: key)
            for id in ids {
                try db.execute(sql: "UPDATE transactions SET category_id = ?, category_source = 'rule' WHERE id = ?",
                               arguments: [categoryID.uuidString, id])
            }
            return CreateCategoryRuleResponse(rule: rule, updatedCount: ids.count)
        }
    }

    /// Visible transactions whose merchant matches `key` and whose category a
    /// person hasn't chosen. Only rows the caller can see: a rule's bulk edit
    /// never reaches into the partner's private transactions. The key is
    /// computed in Swift, so this scans the household's rows — fine at a
    /// couple's volume, and it only runs when someone creates a rule.
    static func matchingIDs(_ db: Database, householdID: UUID, memberID: UUID, key: String) throws -> [String] {
        try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.merchant_name FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            WHERE t.household_id = ?
              AND t.category_source != 'user'
              AND (a.visibility = 'shared' OR a.owner_member_id = ?)
              AND (t.visibility = 'shared' OR t.owner_member_id = ?)
            """, arguments: [householdID.uuidString, memberID.uuidString, memberID.uuidString])
            .compactMap { row -> String? in
                let rowKey = merchantKey(merchantName: row["merchant_name"], name: row["name"])
                return rowKey == key ? row["id"] : nil
            }
    }
}

extension CategoryRule {
    init(row: Row) {
        self.init(id: DBFormat.uuid(row["id"]) ?? UUID(),
                  merchantKey: row["merchant_key"],
                  categoryID: DBFormat.uuid(row["category_id"]) ?? UUID(),
                  createdAt: DBFormat.date(row["created_at"]) ?? Date())
    }
}

extension Request {
    var categoryRules: CategoryRuleStore { CategoryRuleStore(db: appDatabase.dbPool) }
}
