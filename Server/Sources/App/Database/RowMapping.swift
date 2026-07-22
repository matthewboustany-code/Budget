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

extension Transaction {
    init(row: Row) {
        let splitsJSON: String? = row["splits_json"]
        let splits: [TransactionSplit] = splitsJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([TransactionSplit].self, from: $0) } ?? []
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            accountID: DBFormat.uuid(row["account_id"]) ?? UUID(),
            ownerMemberID: DBFormat.uuid(row["owner_member_id"]) ?? UUID(),
            amount: DBFormat.money(row["amount"]),
            date: DBFormat.date(row["date"]) ?? Date(),
            name: row["name"],
            merchantName: row["merchant_name"],
            categoryID: DBFormat.uuid(row["category_id"]),
            status: TransactionStatus(rawValue: row["status"]) ?? .posted,
            note: row["note"],
            isReviewed: DBFormat.bool(row["is_reviewed"]),
            visibility: Visibility(rawValue: row["visibility"]) ?? .shared,
            splits: splits,
            plaidTransactionID: row["plaid_transaction_id"],
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension CategoryGroup {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            name: row["name"],
            isIncome: DBFormat.bool(row["is_income"]),
            sortOrder: row["sort_order"] ?? 0
        )
    }
}

extension BudgetCategory {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            groupID: DBFormat.uuid(row["group_id"]) ?? UUID(),
            name: row["name"],
            icon: row["icon"],
            colorHex: row["color_hex"],
            sortOrder: row["sort_order"] ?? 0,
            isArchived: DBFormat.bool(row["is_archived"])
        )
    }
}

extension Budget {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            categoryID: DBFormat.uuid(row["category_id"]) ?? UUID(),
            month: Month(row["month"]) ?? Month(year: 1970, month: 1),
            amount: DBFormat.money(row["amount"]),
            rolloverEnabled: DBFormat.bool(row["rollover_enabled"])
        )
    }
}

extension TransactionComment {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            transactionID: DBFormat.uuid(row["transaction_id"]) ?? UUID(),
            memberID: DBFormat.uuid(row["member_id"]) ?? UUID(),
            body: row["body"],
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension TransactionReaction {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            transactionID: DBFormat.uuid(row["transaction_id"]) ?? UUID(),
            memberID: DBFormat.uuid(row["member_id"]) ?? UUID(),
            emoji: row["emoji"],
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension RecurringSeries {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            name: row["name"],
            categoryID: DBFormat.uuid(row["category_id"]),
            averageAmount: DBFormat.money(row["average_amount"]),
            cadence: RecurringCadence(rawValue: row["cadence"]) ?? .irregular,
            accountID: DBFormat.uuid(row["account_id"]),
            lastDate: DBFormat.date(row["last_date"]),
            nextDate: DBFormat.date(row["next_date"]),
            isActive: DBFormat.bool(row["is_active"])
        )
    }
}

extension Goal {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            householdID: DBFormat.uuid(row["household_id"]) ?? UUID(),
            name: row["name"],
            targetAmount: DBFormat.money(row["target_amount"]),
            currentAmount: DBFormat.money(row["current_amount"]),
            targetDate: DBFormat.date(row["target_date"]),
            icon: row["icon"],
            colorHex: row["color_hex"],
            createdAt: DBFormat.date(row["created_at"]) ?? Date()
        )
    }
}

extension GoalContribution {
    init(row: Row) {
        self.init(
            id: DBFormat.uuid(row["id"]) ?? UUID(),
            goalID: DBFormat.uuid(row["goal_id"]) ?? UUID(),
            amount: DBFormat.money(row["amount"]),
            date: DBFormat.date(row["date"]) ?? Date(),
            memberID: DBFormat.uuid(row["member_id"]),
            note: row["note"]
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
