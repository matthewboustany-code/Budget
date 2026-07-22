import Foundation

// MARK: - Auth

/// Sent from the app after a successful Sign in with Apple. The server
/// verifies `identityToken` against Apple's public keys.
public struct AppleSignInRequest: Codable, Sendable {
    public var identityToken: String
    public var authorizationCode: String?
    /// Apple provides the name only on the very first sign-in; the app forwards
    /// it so we can seed `displayName`.
    public var fullName: String?

    public init(identityToken: String, authorizationCode: String? = nil, fullName: String? = nil) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.fullName = fullName
    }
}

/// Returned by `POST /v1/auth/apple`. `household`/`member` are nil until the
/// user creates or joins one, which the app uses to route onboarding.
public struct AuthResponse: Codable, Sendable {
    public var token: String
    public var user: User
    public var household: Household?
    public var member: HouseholdMember?

    public init(token: String, user: User, household: Household? = nil, member: HouseholdMember? = nil) {
        self.token = token
        self.user = user
        self.household = household
        self.member = member
    }
}

/// The `GET /v1/me` payload: who I am and the household I'm in.
public struct MeResponse: Codable, Sendable {
    public var user: User
    public var household: Household?
    public var member: HouseholdMember?
    public var members: [HouseholdMember]

    public init(user: User, household: Household? = nil,
                member: HouseholdMember? = nil, members: [HouseholdMember] = []) {
        self.user = user
        self.household = household
        self.member = member
        self.members = members
    }
}

// MARK: - Household

public struct CreateHouseholdRequest: Codable, Sendable {
    public var name: String
    public var memberDisplayName: String
    public init(name: String, memberDisplayName: String) {
        self.name = name
        self.memberDisplayName = memberDisplayName
    }
}

public struct JoinHouseholdRequest: Codable, Sendable {
    public var code: String
    public var memberDisplayName: String
    public init(code: String, memberDisplayName: String) {
        self.code = code
        self.memberDisplayName = memberDisplayName
    }
}

public struct InviteResponse: Codable, Sendable {
    public var code: String
    public var expiresAt: Date
    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

// MARK: - Plaid

public struct LinkTokenResponse: Codable, Sendable {
    public var linkToken: String
    public var expiration: Date?
    public init(linkToken: String, expiration: Date? = nil) {
        self.linkToken = linkToken
        self.expiration = expiration
    }
}

/// Sent after Plaid Link succeeds on the device. We exchange the public token
/// for a long-lived access token server-side; the app never sees it.
public struct ExchangePublicTokenRequest: Codable, Sendable {
    public var publicToken: String
    public var institutionName: String?
    /// Default visibility to apply to the newly linked accounts.
    public var visibility: Visibility
    public init(publicToken: String, institutionName: String? = nil, visibility: Visibility = .shared) {
        self.publicToken = publicToken
        self.institutionName = institutionName
        self.visibility = visibility
    }
}

// MARK: - Transactions

/// A page of transactions plus a cursor for the next page (nil when done).
public struct TransactionPage: Codable, Sendable {
    public var transactions: [Transaction]
    public var nextCursor: String?
    public init(transactions: [Transaction], nextCursor: String? = nil) {
        self.transactions = transactions
        self.nextCursor = nextCursor
    }
}

/// Partial update to a transaction. Only non-nil fields are applied
/// (PATCH semantics); `clearCategory` distinguishes "leave as-is" from
/// "set to uncategorized".
public struct UpdateTransactionRequest: Codable, Sendable {
    public var categoryID: UUID?
    public var clearCategory: Bool?
    public var note: String?
    public var isReviewed: Bool?
    public var visibility: Visibility?
    public var splits: [TransactionSplit]?

    public init(categoryID: UUID? = nil, clearCategory: Bool? = nil, note: String? = nil,
                isReviewed: Bool? = nil, visibility: Visibility? = nil,
                splits: [TransactionSplit]? = nil) {
        self.categoryID = categoryID
        self.clearCategory = clearCategory
        self.note = note
        self.isReviewed = isReviewed
        self.visibility = visibility
        self.splits = splits
    }
}

public struct AddCommentRequest: Codable, Sendable {
    public var body: String
    public init(body: String) { self.body = body }
}

public struct AddReactionRequest: Codable, Sendable {
    public var emoji: String
    public init(emoji: String) { self.emoji = emoji }
}

// MARK: - Accounts

/// Partial update to an account (owner-only for visibility). Only non-nil
/// fields are applied.
public struct UpdateAccountRequest: Codable, Sendable {
    public var name: String?
    public var visibility: Visibility?
    public var isHidden: Bool?
    public init(name: String? = nil, visibility: Visibility? = nil, isHidden: Bool? = nil) {
        self.name = name
        self.visibility = visibility
        self.isHidden = isHidden
    }
}

/// Current net worth plus the stored daily snapshot series for charting.
public struct NetWorthResponse: Codable, Sendable {
    public var current: NetWorthPoint
    public var series: [NetWorthPoint]
    public init(current: NetWorthPoint, series: [NetWorthPoint]) {
        self.current = current
        self.series = series
    }
}

/// Dev-only: link a Plaid sandbox institution without the Link UI.
public struct SandboxLinkRequest: Codable, Sendable {
    public var institutionId: String?
    public var institutionName: String?
    public var visibility: Visibility
    public init(institutionId: String? = nil, institutionName: String? = nil, visibility: Visibility = .shared) {
        self.institutionId = institutionId
        self.institutionName = institutionName
        self.visibility = visibility
    }
}

// MARK: - Categories

/// The household's category tree (groups + their categories).
public struct CategoriesResponse: Codable, Sendable {
    public var groups: [CategoryGroup]
    public var categories: [BudgetCategory]
    public init(groups: [CategoryGroup], categories: [BudgetCategory]) {
        self.groups = groups
        self.categories = categories
    }
}

// MARK: - Transaction detail (couples layer)

/// A transaction plus its comment thread and reactions, for the detail screen.
public struct TransactionDetailResponse: Codable, Sendable {
    public var transaction: Transaction
    public var comments: [TransactionComment]
    public var reactions: [TransactionReaction]
    public init(transaction: Transaction, comments: [TransactionComment], reactions: [TransactionReaction]) {
        self.transaction = transaction
        self.comments = comments
        self.reactions = reactions
    }
}

// MARK: - Budgets

/// Upsert a category's budget for a month (used by `PUT /v1/budgets/:categoryID`).
public struct SetBudgetRequest: Codable, Sendable {
    public var month: Month
    public var amount: Money
    public var rolloverEnabled: Bool
    public init(month: Month, amount: Money, rolloverEnabled: Bool = false) {
        self.month = month
        self.amount = amount
        self.rolloverEnabled = rolloverEnabled
    }
}

/// The `GET /v1/budgets?month=` payload: the month's stored budgets (source of
/// truth for the editor — amount + rollover flag) plus the computed
/// budget-vs-actual rollup. Spent totals reflect only transactions visible to
/// the requesting member, so partners may see different numbers for a category
/// that has private activity — consistent with every other route.
public struct BudgetMonthResponse: Codable, Sendable {
    public var month: Month
    public var budgets: [Budget]
    public var rollup: MonthBudget
    public init(month: Month, budgets: [Budget], rollup: MonthBudget) {
        self.month = month
        self.budgets = budgets
        self.rollup = rollup
    }
}

// MARK: - Category CRUD

public struct CreateCategoryRequest: Codable, Sendable {
    public var groupID: UUID
    public var name: String
    public var icon: String?
    public var colorHex: String?
    public init(groupID: UUID, name: String, icon: String? = nil, colorHex: String? = nil) {
        self.groupID = groupID
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
    }
}

/// Partial update to a category. Only non-nil fields are applied.
public struct UpdateCategoryRequest: Codable, Sendable {
    public var name: String?
    public var icon: String?
    public var colorHex: String?
    public var sortOrder: Int?
    public var isArchived: Bool?
    public init(name: String? = nil, icon: String? = nil, colorHex: String? = nil,
                sortOrder: Int? = nil, isArchived: Bool? = nil) {
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.isArchived = isArchived
    }
}

// MARK: - Recurring & bills

/// Partial update to a recurring series. Only non-nil fields are applied;
/// `clearCategory` distinguishes "leave as-is" from "set to uncategorized".
/// Setting `isActive: false` is how the user says "this isn't a bill" — the
/// detector never flips it back.
public struct UpdateRecurringRequest: Codable, Sendable {
    public var name: String?
    public var categoryID: UUID?
    public var clearCategory: Bool?
    public var isActive: Bool?
    public init(name: String? = nil, categoryID: UUID? = nil,
                clearCategory: Bool? = nil, isActive: Bool? = nil) {
        self.name = name
        self.categoryID = categoryID
        self.clearCategory = clearCategory
        self.isActive = isActive
    }
}

/// The `GET /v1/bills/upcoming` payload: occurrences projected from the
/// caller's visible active series over `[from, to]`. Never stored — see
/// `BillProjector`.
public struct UpcomingBillsResponse: Codable, Sendable {
    public var from: Date
    public var to: Date
    public var bills: [Bill]
    public init(from: Date, to: Date, bills: [Bill]) {
        self.from = from
        self.to = to
        self.bills = bills
    }
}

// MARK: - Goals

public struct CreateGoalRequest: Codable, Sendable {
    public var name: String
    public var targetAmount: Money
    public var targetDate: Date?
    public var icon: String?
    public var colorHex: String?
    public init(name: String, targetAmount: Money, targetDate: Date? = nil,
                icon: String? = nil, colorHex: String? = nil) {
        self.name = name
        self.targetAmount = targetAmount
        self.targetDate = targetDate
        self.icon = icon
        self.colorHex = colorHex
    }
}

/// Partial update to a goal. Only non-nil fields are applied; `clearTargetDate`
/// distinguishes "leave as-is" from "remove the deadline".
public struct UpdateGoalRequest: Codable, Sendable {
    public var name: String?
    public var targetAmount: Money?
    public var targetDate: Date?
    public var clearTargetDate: Bool?
    public var icon: String?
    public var colorHex: String?
    public init(name: String? = nil, targetAmount: Money? = nil, targetDate: Date? = nil,
                clearTargetDate: Bool? = nil, icon: String? = nil, colorHex: String? = nil) {
        self.name = name
        self.targetAmount = targetAmount
        self.targetDate = targetDate
        self.clearTargetDate = clearTargetDate
        self.icon = icon
        self.colorHex = colorHex
    }
}

/// Add money to (positive) or withdraw from (negative) a goal. `date` defaults
/// to now server-side.
public struct AddContributionRequest: Codable, Sendable {
    public var amount: Money
    public var date: Date?
    public var note: String?
    public init(amount: Money, date: Date? = nil, note: String? = nil) {
        self.amount = amount
        self.date = date
        self.note = note
    }
}

/// A goal plus its contribution history, for the detail screen.
public struct GoalDetailResponse: Codable, Sendable {
    public var goal: Goal
    public var contributions: [GoalContribution]
    public init(goal: Goal, contributions: [GoalContribution]) {
        self.goal = goal
        self.contributions = contributions
    }
}

// MARK: - Reports

/// The `GET /v1/reports/cashflow` payload: one summary per month, oldest
/// first, ending at the current month. Transactions in the household's
/// "Transfer" category are excluded — moving money between your own accounts
/// is neither income nor spending.
public struct CashFlowReportResponse: Codable, Sendable {
    public var months: [CashFlowSummary]
    public init(months: [CashFlowSummary]) {
        self.months = months
    }
}

/// The `GET /v1/reports/spending?month=` payload: per-category outflows,
/// highest first, with budgets attached for comparison. Transfers excluded,
/// same as cash flow.
public struct SpendingReportResponse: Codable, Sendable {
    public var month: Month
    public var entries: [SpendingByCategory]
    public var total: Money
    public init(month: Month, entries: [SpendingByCategory], total: Money) {
        self.month = month
        self.entries = entries
        self.total = total
    }
}

// MARK: - Errors

/// Uniform error body the server returns and the app decodes for messaging.
public struct APIErrorResponse: Codable, Sendable, Error {
    public var error: Bool
    public var reason: String
    public init(error: Bool = true, reason: String) {
        self.error = error
        self.reason = reason
    }
}
