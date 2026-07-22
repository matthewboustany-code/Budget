import Foundation
import GRDB
import BudgetModels

// Map GRDB rows to the shared wire DTOs. Kept in the Server target so
// BudgetModels stays GRDB-free. Columns are the snake_case names from
// Migrations.swift.

extension User {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            appleUserID: row["apple_user_id"],
            email: row["email"],
            displayName: row["display_name"],
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension Household {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            name: row["name"],
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension Account {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            ownerMemberID: DBFormat.uuid(row["owner_member_id"]) ?? UUID(),
            name: row["name"],
            officialName: row["official_name"],
            type: AccountType(rawValue: row["type"]) ?? .other,
            currentBalance: DBFormat.money(row["current_balance"]),
            availableBalance: DBFormat.optMoney(row["available_balance"]),
            currencyCode: row["currency_code"] ?? "USD",
            institutionName: row["institution_name"],
            mask: row["mask"],
            visibility: Visibility(rawValue: row["visibility"]) ?? .shared,
            isHidden: DBFormat.bool(row["is_hidden"]),
            plaidAccountID: row["plaid_account_id"],
            lastSyncedAt: DBFormat.date(row["last_synced_at"]),
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension HouseholdMember {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            userID: DBFormat.uuid(row["user_id"]) ?? UUID(),
            displayName: row["display_name"],
            role: MemberRole(rawValue: row["role"]) ?? .member,
            colorHex: row["color_hex"],
            joinedAt: DBFormat.date(row["joined_at"]) ?? Date()
        )
    }
}
