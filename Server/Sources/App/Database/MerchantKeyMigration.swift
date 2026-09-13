import Foundation
import GRDB
import BudgetKit

/// Re-keys stored merchant keys after `RecurringDetector.normalize` changed
/// (v11). Run inside the migration's write transaction; idempotent.
enum MerchantKeyMigration {
    static func rekey(_ db: Database) throws {
        // Recurring series keep their display name, so re-derive from it.
        // Two series may now share a key; `mergeDetected` keeps the first row.
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM recurring_series") {
            let name: String = row["name"]
            let id: String = row["id"]
            try db.execute(sql: "UPDATE recurring_series SET merchant_key = ? WHERE id = ?",
                           arguments: [RecurringDetector.normalize(name), id])
        }

        // A rule stores only its old key, and the old normalizer destroyed
        // information ("netflixcom"). Recover the merchant from a household
        // transaction that produced that old key; else re-normalize the key.
        for row in try Row.fetchAll(db, sql: "SELECT id, household_id, merchant_key FROM category_rules ORDER BY created_at") {
            let id: String = row["id"]
            let household: String = row["household_id"]
            let oldKey: String = row["merchant_key"]
            let source = try Row.fetchAll(
                db, sql: "SELECT name, merchant_name FROM transactions WHERE household_id = ?",
                arguments: [household])
                .lazy
                .map { ($0["merchant_name"] as String?) ?? ($0["name"] as String) }
                .first { RecurringDetector.legacyNormalize($0) == oldKey }
            let newKey = RecurringDetector.normalize(source ?? oldKey)
            guard newKey != oldKey else { continue }
            // UNIQUE(household_id, merchant_key): if an older rule already
            // owns the new key, that one wins and this duplicate goes.
            let taken = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM category_rules WHERE household_id = ? AND merchant_key = ? AND id != ?)
                """, arguments: [household, newKey, id]) ?? false
            if taken || newKey.isEmpty {
                try db.execute(sql: "DELETE FROM category_rules WHERE id = ?", arguments: [id])
            } else {
                try db.execute(sql: "UPDATE category_rules SET merchant_key = ? WHERE id = ?", arguments: [newKey, id])
            }
        }
    }
}
