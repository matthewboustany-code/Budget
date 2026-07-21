import Foundation

/// A money movement. Positive `amount` = outflow (spending), negative =
/// inflow (income), matching Plaid. A transaction inherits its account's
/// owner but carries its own `visibility` so a single charge can be hidden
/// even on a shared account.
public struct Transaction: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var householdID: UUID
    public var accountID: UUID
    public var ownerMemberID: UUID
    public var amount: Money
    public var date: Date
    /// Merchant / payee display name.
    public var name: String
    public var merchantName: String?
    /// nil means uncategorized.
    public var categoryID: UUID?
    public var status: TransactionStatus
    /// Free-text note added by a member.
    public var note: String?
    /// Members mark transactions reviewed as they reconcile the month.
    public var isReviewed: Bool
    public var visibility: Visibility
    /// If non-empty, the transaction is split across categories and `categoryID`
    /// is ignored in budget math (the splits are used instead).
    public var splits: [TransactionSplit]
    public var plaidTransactionID: String?
    public var createdAt: Date

    public init(id: UUID, householdID: UUID, accountID: UUID, ownerMemberID: UUID,
                amount: Money, date: Date, name: String, merchantName: String? = nil,
                categoryID: UUID? = nil, status: TransactionStatus = .posted,
                note: String? = nil, isReviewed: Bool = false,
                visibility: Visibility = .shared, splits: [TransactionSplit] = [],
                plaidTransactionID: String? = nil, createdAt: Date) {
        self.id = id
        self.householdID = householdID
        self.accountID = accountID
        self.ownerMemberID = ownerMemberID
        self.amount = amount
        self.date = date
        self.name = name
        self.merchantName = merchantName
        self.categoryID = categoryID
        self.status = status
        self.note = note
        self.isReviewed = isReviewed
        self.visibility = visibility
        self.splits = splits
        self.plaidTransactionID = plaidTransactionID
        self.createdAt = createdAt
    }

    public var isSplit: Bool { !splits.isEmpty }
    public var isOutflow: Bool { amount > 0 }
    public var isInflow: Bool { amount < 0 }
}

/// One leg of a split transaction. Split amounts should sum to the parent
/// transaction's amount (validated in BudgetKit).
public struct TransactionSplit: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var categoryID: UUID?
    public var amount: Money
    public var note: String?

    public init(id: UUID, categoryID: UUID? = nil, amount: Money, note: String? = nil) {
        self.id = id
        self.categoryID = categoryID
        self.amount = amount
        self.note = note
    }
}

/// A partner's chat message on a transaction (Honeydue's per-transaction chat).
public struct TransactionComment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var transactionID: UUID
    public var memberID: UUID
    public var body: String
    public var createdAt: Date

    public init(id: UUID, transactionID: UUID, memberID: UUID, body: String, createdAt: Date) {
        self.id = id
        self.transactionID = transactionID
        self.memberID = memberID
        self.body = body
        self.createdAt = createdAt
    }
}

/// A single emoji reaction from one member on a transaction.
public struct TransactionReaction: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var transactionID: UUID
    public var memberID: UUID
    public var emoji: String
    public var createdAt: Date

    public init(id: UUID, transactionID: UUID, memberID: UUID, emoji: String, createdAt: Date) {
        self.id = id
        self.transactionID = transactionID
        self.memberID = memberID
        self.emoji = emoji
        self.createdAt = createdAt
    }
}
