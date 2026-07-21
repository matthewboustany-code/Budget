import Foundation
import GRDB

extension AppDatabase {
    /// Versioned schema. New changes append a new `registerMigration` block;
    /// never edit a shipped one. Money is stored as exact `Decimal` strings
    /// (TEXT) and summed in Swift via BudgetKit, so we never rely on SQLite's
    /// binary floating point for currency. Dates are ISO8601 TEXT.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // In development, wipe & rebuild when a migration changes shape. Guarded
        // so it can be disabled in production.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_core_schema") { db in
            try db.execute(sql: """
            CREATE TABLE users (
                id TEXT PRIMARY KEY,
                apple_user_id TEXT NOT NULL UNIQUE,
                email TEXT,
                display_name TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE households (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE TABLE memberships (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                role TEXT NOT NULL,
                color_hex TEXT,
                joined_at TEXT NOT NULL,
                UNIQUE(household_id, user_id)
            );

            CREATE TABLE invite_codes (
                code TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                expires_at TEXT NOT NULL
            );

            CREATE TABLE plaid_items (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                owner_member_id TEXT NOT NULL REFERENCES memberships(id) ON DELETE CASCADE,
                plaid_item_id TEXT NOT NULL UNIQUE,
                access_token_encrypted TEXT NOT NULL,
                institution_name TEXT,
                transactions_cursor TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE accounts (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                owner_member_id TEXT NOT NULL REFERENCES memberships(id) ON DELETE CASCADE,
                plaid_item_id TEXT REFERENCES plaid_items(id) ON DELETE CASCADE,
                plaid_account_id TEXT,
                name TEXT NOT NULL,
                official_name TEXT,
                type TEXT NOT NULL,
                current_balance TEXT NOT NULL,
                available_balance TEXT,
                currency_code TEXT NOT NULL DEFAULT 'USD',
                institution_name TEXT,
                mask TEXT,
                visibility TEXT NOT NULL DEFAULT 'shared',
                is_hidden INTEGER NOT NULL DEFAULT 0,
                last_synced_at TEXT,
                created_at TEXT NOT NULL
            );
            CREATE INDEX idx_accounts_household ON accounts(household_id);

            CREATE TABLE category_groups (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                is_income INTEGER NOT NULL DEFAULT 0,
                sort_order INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE categories (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL REFERENCES category_groups(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                icon TEXT,
                color_hex TEXT,
                sort_order INTEGER NOT NULL DEFAULT 0,
                is_archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX idx_categories_household ON categories(household_id);

            CREATE TABLE transactions (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                owner_member_id TEXT NOT NULL REFERENCES memberships(id) ON DELETE CASCADE,
                amount TEXT NOT NULL,
                date TEXT NOT NULL,
                name TEXT NOT NULL,
                merchant_name TEXT,
                category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
                status TEXT NOT NULL DEFAULT 'posted',
                note TEXT,
                is_reviewed INTEGER NOT NULL DEFAULT 0,
                visibility TEXT NOT NULL DEFAULT 'shared',
                splits_json TEXT,
                plaid_transaction_id TEXT UNIQUE,
                created_at TEXT NOT NULL
            );
            CREATE INDEX idx_tx_household_date ON transactions(household_id, date);
            CREATE INDEX idx_tx_account ON transactions(account_id);
            CREATE INDEX idx_tx_category ON transactions(category_id);

            CREATE TABLE budgets (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
                month TEXT NOT NULL,
                amount TEXT NOT NULL,
                rollover_enabled INTEGER NOT NULL DEFAULT 0,
                UNIQUE(category_id, month)
            );

            CREATE TABLE recurring_series (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
                average_amount TEXT NOT NULL,
                cadence TEXT NOT NULL,
                account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
                last_date TEXT,
                next_date TEXT,
                is_active INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE bills (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                recurring_series_id TEXT REFERENCES recurring_series(id) ON DELETE SET NULL,
                name TEXT NOT NULL,
                amount TEXT NOT NULL,
                due_date TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'upcoming',
                category_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
                note TEXT
            );
            CREATE INDEX idx_bills_household_due ON bills(household_id, due_date);

            CREATE TABLE goals (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                target_amount TEXT NOT NULL,
                current_amount TEXT NOT NULL DEFAULT '0',
                target_date TEXT,
                icon TEXT,
                color_hex TEXT,
                created_at TEXT NOT NULL
            );

            CREATE TABLE goal_contributions (
                id TEXT PRIMARY KEY,
                goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
                amount TEXT NOT NULL,
                date TEXT NOT NULL,
                member_id TEXT REFERENCES memberships(id) ON DELETE SET NULL,
                note TEXT
            );

            CREATE TABLE transaction_comments (
                id TEXT PRIMARY KEY,
                transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                member_id TEXT NOT NULL REFERENCES memberships(id) ON DELETE CASCADE,
                body TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE INDEX idx_comments_tx ON transaction_comments(transaction_id);

            CREATE TABLE transaction_reactions (
                id TEXT PRIMARY KEY,
                transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                member_id TEXT NOT NULL REFERENCES memberships(id) ON DELETE CASCADE,
                emoji TEXT NOT NULL,
                created_at TEXT NOT NULL,
                UNIQUE(transaction_id, member_id, emoji)
            );

            CREATE TABLE net_worth_snapshots (
                id TEXT PRIMARY KEY,
                household_id TEXT NOT NULL REFERENCES households(id) ON DELETE CASCADE,
                date TEXT NOT NULL,
                assets TEXT NOT NULL,
                liabilities TEXT NOT NULL,
                UNIQUE(household_id, date)
            );
            """)
        }

        return migrator
    }
}
