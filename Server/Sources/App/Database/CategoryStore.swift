import Foundation
import GRDB
import Vapor
import BudgetModels

/// Category groups + categories for a household, plus the default tree seeded on
/// household creation. Category names are the join point for auto-categorization
/// (see `CategorySeeder.plaidCategoryName`).
struct CategoryStore {
    let db: DatabasePool

    func list(householdID: UUID) async throws -> CategoriesResponse {
        try await db.read { db in
            let groups = try Row.fetchAll(db, sql: "SELECT * FROM category_groups WHERE household_id = ? ORDER BY sort_order",
                                          arguments: [householdID.uuidString]).map(CategoryGroup.init(row:))
            let categories = try Row.fetchAll(db, sql: "SELECT * FROM categories WHERE household_id = ? AND is_archived = 0 ORDER BY sort_order",
                                              arguments: [householdID.uuidString]).map(BudgetCategory.init(row:))
            return CategoriesResponse(groups: groups, categories: categories)
        }
    }

    func get(id: UUID) async throws -> BudgetCategory? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM categories WHERE id = ?", arguments: [id.uuidString])
                .map(BudgetCategory.init(row:))
        }
    }

    func getGroup(id: UUID) async throws -> CategoryGroup? {
        try await db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM category_groups WHERE id = ?", arguments: [id.uuidString])
                .map(CategoryGroup.init(row:))
        }
    }

    /// Creates a custom category at the end of its group.
    func create(householdID: UUID, groupID: UUID, name: String,
                icon: String?, colorHex: String?) async throws -> BudgetCategory {
        try await db.write { db in
            let maxSort = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM categories WHERE group_id = ?",
                                           arguments: [groupID.uuidString]) ?? 0
            let category = BudgetCategory(id: UUID(), householdID: householdID, groupID: groupID,
                                          name: name, icon: icon, colorHex: colorHex,
                                          sortOrder: maxSort + 1)
            try db.execute(sql: """
                INSERT INTO categories (id, household_id, group_id, name, icon, color_hex, sort_order, is_archived)
                VALUES (?,?,?,?,?,?,?,0)
                """, arguments: [category.id.uuidString, householdID.uuidString, groupID.uuidString,
                                 category.name, category.icon, category.colorHex, category.sortOrder])
            return category
        }
    }

    /// PATCH semantics: only non-nil fields are applied.
    func update(id: UUID, _ body: UpdateCategoryRequest) async throws {
        try await db.write { db in
            if let name = body.name {
                try db.execute(sql: "UPDATE categories SET name = ? WHERE id = ?", arguments: [name, id.uuidString])
            }
            if let icon = body.icon {
                try db.execute(sql: "UPDATE categories SET icon = ? WHERE id = ?", arguments: [icon, id.uuidString])
            }
            if let colorHex = body.colorHex {
                try db.execute(sql: "UPDATE categories SET color_hex = ? WHERE id = ?", arguments: [colorHex, id.uuidString])
            }
            if let sortOrder = body.sortOrder {
                try db.execute(sql: "UPDATE categories SET sort_order = ? WHERE id = ?", arguments: [sortOrder, id.uuidString])
            }
            if let isArchived = body.isArchived {
                try db.execute(sql: "UPDATE categories SET is_archived = ? WHERE id = ?",
                               arguments: [isArchived ? 1 : 0, id.uuidString])
            }
        }
    }

    /// Delete = archive. Transactions keep their `category_id` (history stays
    /// intact); the category just disappears from lists and pickers.
    func archive(id: UUID) async throws {
        try await update(id: id, UpdateCategoryRequest(isArchived: true))
    }
}

extension Request {
    var categories: CategoryStore { CategoryStore(db: appDatabase.dbPool) }
}

/// Seeds a Monarch-style default category tree. Run inside the household-create
/// transaction so a new household is immediately usable.
enum CategorySeeder {
    struct Group { let name: String; let isIncome: Bool; let categories: [(name: String, icon: String)] }

    static let tree: [Group] = [
        Group(name: "Income", isIncome: true, categories: [
            ("Paycheck", "dollarsign.arrow.circlepath"), ("Other Income", "plus.circle")]),
        Group(name: "Essentials", isIncome: false, categories: [
            ("Groceries", "cart"), ("Rent & Utilities", "house"),
            ("Transportation", "car"), ("Medical", "cross.case")]),
        Group(name: "Lifestyle", isIncome: false, categories: [
            ("Dining & Drinks", "fork.knife"), ("Shopping", "bag"),
            ("Entertainment", "film"), ("Travel", "airplane"), ("Personal Care", "figure.walk")]),
        Group(name: "Financial", isIncome: false, categories: [
            ("Loan Payments", "banknote"), ("Bank Fees", "building.columns"), ("Services", "wrench.and.screwdriver")]),
        Group(name: "Other", isIncome: false, categories: [
            ("Home", "hammer"), ("Government & Nonprofit", "building.2"), ("Transfer", "arrow.left.arrow.right")]),
    ]

    static func seed(householdID: UUID, _ db: Database) throws {
        var groupSort = 0
        var catSort = 0
        for group in tree {
            let groupID = UUID()
            try db.execute(sql: "INSERT INTO category_groups (id, household_id, name, is_income, sort_order) VALUES (?,?,?,?,?)",
                           arguments: [groupID.uuidString, householdID.uuidString, group.name, group.isIncome ? 1 : 0, groupSort])
            groupSort += 1
            for category in group.categories {
                try db.execute(sql: "INSERT INTO categories (id, household_id, group_id, name, icon, sort_order, is_archived) VALUES (?,?,?,?,?,?,0)",
                               arguments: [UUID().uuidString, householdID.uuidString, groupID.uuidString,
                                           category.name, category.icon, catSort])
                catSort += 1
            }
        }
    }

    /// Maps a Plaid personal-finance-category to one of our seeded category
    /// names (nil → leave uncategorized).
    static func plaidCategoryName(primary: String?, detailed: String?) -> String? {
        if detailed?.contains("GROCERIES") == true { return "Groceries" }
        switch primary {
        case "INCOME": return "Paycheck"
        case "TRANSFER_IN", "TRANSFER_OUT": return "Transfer"
        case "LOAN_PAYMENTS": return "Loan Payments"
        case "BANK_FEES": return "Bank Fees"
        case "ENTERTAINMENT": return "Entertainment"
        case "FOOD_AND_DRINK": return "Dining & Drinks"
        case "GENERAL_MERCHANDISE": return "Shopping"
        case "GENERAL_SERVICES": return "Services"
        case "GOVERNMENT_AND_NON_PROFIT": return "Government & Nonprofit"
        case "HOME_IMPROVEMENT": return "Home"
        case "MEDICAL": return "Medical"
        case "PERSONAL_CARE": return "Personal Care"
        case "RENT_AND_UTILITIES": return "Rent & Utilities"
        case "TRANSPORTATION": return "Transportation"
        case "TRAVEL": return "Travel"
        default: return nil
        }
    }
}
