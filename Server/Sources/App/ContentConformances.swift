import Vapor
import BudgetModels

/// The shared DTOs are plain `Codable` in the Vapor-free `BudgetModels` package.
/// Conforming them to Vapor's `Content` here (retroactively) lets routes decode
/// request bodies and encode responses without pulling Vapor into the package.
/// Vapor supplies the encode/decode implementations for any `Codable` type.

extension AppleSignInRequest: @retroactive Content {}
extension AuthResponse: @retroactive Content {}
extension MeResponse: @retroactive Content {}
extension CreateHouseholdRequest: @retroactive Content {}
extension JoinHouseholdRequest: @retroactive Content {}
extension InviteResponse: @retroactive Content {}

// Accounts & Plaid (P2)
extension Account: @retroactive Content {}
extension LinkTokenResponse: @retroactive Content {}
extension ExchangePublicTokenRequest: @retroactive Content {}
extension SandboxLinkRequest: @retroactive Content {}
extension UpdateAccountRequest: @retroactive Content {}
extension NetWorthResponse: @retroactive Content {}

// Transactions, categories & couples layer (P3)
extension Transaction: @retroactive Content {}
extension TransactionPage: @retroactive Content {}
extension TransactionDetailResponse: @retroactive Content {}
extension UpdateTransactionRequest: @retroactive Content {}
extension BudgetCategory: @retroactive Content {}
extension CategoryGroup: @retroactive Content {}
extension CategoriesResponse: @retroactive Content {}
extension TransactionComment: @retroactive Content {}
extension TransactionReaction: @retroactive Content {}
extension AddCommentRequest: @retroactive Content {}
extension AddReactionRequest: @retroactive Content {}

// Budgets & category CRUD (P4)
extension Budget: @retroactive Content {}
extension SetBudgetRequest: @retroactive Content {}
extension BudgetMonthResponse: @retroactive Content {}
extension CreateCategoryRequest: @retroactive Content {}
extension UpdateCategoryRequest: @retroactive Content {}

// Bills, recurring & goals (P5)
extension RecurringSeries: @retroactive Content {}
extension UpdateRecurringRequest: @retroactive Content {}
extension UpcomingBillsResponse: @retroactive Content {}
extension Goal: @retroactive Content {}
extension CreateGoalRequest: @retroactive Content {}
extension UpdateGoalRequest: @retroactive Content {}
extension AddContributionRequest: @retroactive Content {}
extension GoalDetailResponse: @retroactive Content {}
