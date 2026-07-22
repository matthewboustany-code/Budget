import Foundation
import GRDB
import Vapor
import BudgetModels

/// Orchestrates Plaid linking and balance sync: exchange a public token, store
/// the item (token encrypted), and pull accounts. Also refreshes balances for
/// the nightly command.
struct AccountSyncService {
    let db: DatabasePool
    let plaid: PlaidClient
    let cipher: TokenCipher

    /// Exchange a public token → store item → pull & persist accounts.
    func linkPublicToken(_ publicToken: String, householdID: UUID, ownerMemberID: UUID,
                         institutionName: String?, visibility: Visibility) async throws -> [Account] {
        let exchange = try await plaid.exchangePublicToken(publicToken)
        let encrypted = try cipher.encrypt(exchange.accessToken)
        let itemID = UUID()

        let accountsResponse = try await plaid.getAccounts(accessToken: exchange.accessToken)
        let institution = institutionName ?? accountsResponse.item?.institutionId

        try await PlaidItemStore(db: db).create(PlaidItemRecord(
            id: itemID, householdID: householdID, ownerMemberID: ownerMemberID,
            plaidItemID: exchange.itemId, accessTokenEncrypted: encrypted, institutionName: institution))

        var synced: [Account] = []
        try await db.write { db in
            for plaidAccount in accountsResponse.accounts {
                let account = Self.map(plaidAccount, householdID: householdID, ownerMemberID: ownerMemberID,
                                       institutionName: institution, visibility: visibility)
                try AccountStore.upsertPlaidAccount(account, plaidItemID: itemID, db)
                synced.append(account)
            }
        }
        return synced
    }

    /// Refresh balances for one stored item.
    func refreshBalances(item: PlaidItemRecord) async throws {
        let token = try cipher.decrypt(item.accessTokenEncrypted)
        let response = try await plaid.getAccounts(accessToken: token)
        let now = Date()
        try await db.write { db in
            for plaidAccount in response.accounts {
                try AccountStore.updateBalance(
                    plaidAccountID: plaidAccount.accountId,
                    current: Self.decimal(plaidAccount.balances.current),
                    available: plaidAccount.balances.available.map(Self.decimal),
                    syncedAt: now, db)
            }
        }
    }

    // MARK: - Mapping

    static func map(_ pa: PlaidAccount, householdID: UUID, ownerMemberID: UUID,
                    institutionName: String?, visibility: Visibility) -> Account {
        Account(id: UUID(), householdID: householdID, ownerMemberID: ownerMemberID,
                name: pa.name, officialName: pa.officialName, type: mapType(pa.type, pa.subtype),
                currentBalance: decimal(pa.balances.current),
                availableBalance: pa.balances.available.map(decimal),
                currencyCode: pa.balances.isoCurrencyCode ?? "USD",
                institutionName: institutionName, mask: pa.mask, visibility: visibility,
                plaidAccountID: pa.accountId, lastSyncedAt: Date(), createdAt: Date())
    }

    static func mapType(_ type: String, _ subtype: String?) -> AccountType {
        switch type {
        case "depository":
            switch subtype {
            case "savings", "cd", "money market", "hsa": return .savings
            default: return .checking
            }
        case "credit": return .creditCard
        case "loan": return .loan
        case "investment", "brokerage": return .investment
        default: return .other
        }
    }

    /// Plaid sends amounts as JSON numbers; go via string to avoid binary FP drift.
    static func decimal(_ value: Double?) -> Money {
        guard let value else { return 0 }
        return Decimal(string: String(format: "%.2f", value)) ?? 0
    }
}

extension Request {
    var accountSync: AccountSyncService {
        AccountSyncService(db: appDatabase.dbPool, plaid: plaid,
                           cipher: TokenCipher(secret: appConfig.plaidTokenEncKey))
    }

    /// The caller's household + membership, or a 403 if they haven't set one up.
    func requireMembership() async throws -> (Household, HouseholdMember) {
        let user = try requireUser()
        guard let member = try await households.membership(userID: user.id),
              let household = try await households.household(id: member.householdID) else {
            throw Abort(.forbidden, reason: "Create or join a household first.")
        }
        return (household, member)
    }
}
