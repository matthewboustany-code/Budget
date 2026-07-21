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
