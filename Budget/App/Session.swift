import Foundation
import Observation
import BudgetModels

/// Authentication + household state for the signed-in user. The bearer token
/// lives in the Keychain; this holds the decoded identity for the UI and
/// exposes a token reader the `APIClient` uses to attach the bearer header.
@MainActor
@Observable
final class Session {
    enum State: Equatable { case unknown, signedOut, signedIn }

    private(set) var state: State = .unknown
    private(set) var user: User?
    private(set) var household: Household?
    private(set) var member: HouseholdMember?
    private(set) var members: [HouseholdMember] = []

    private let keychain = Keychain()
    private let tokenAccount = "bearer"

    /// Closure the API client calls to attach the bearer token to a request.
    var tokenReader: () -> String? {
        let kc = keychain
        let account = tokenAccount
        return { kc.get(account) }
    }

    init() {
        // Honor `-serverBaseURL <url>` for pointing the sim at a local server
        // (FlightBag's launch-arg convention).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-serverBaseURL"), i + 1 < args.count {
            ServerConfig.setBaseURL(args[i + 1])
        }
        state = keychain.get(tokenAccount) == nil ? .signedOut : .signedIn
    }

    var isSignedIn: Bool { state == .signedIn }
    /// Signed in with Apple but not yet in a household — drives onboarding.
    var needsHousehold: Bool { state == .signedIn && household == nil }

    func apply(_ response: AuthResponse) {
        keychain.set(response.token, for: tokenAccount)
        user = response.user
        household = response.household
        member = response.member
        if let member { members = [member] }
        state = .signedIn
    }

    func apply(_ me: MeResponse) {
        user = me.user
        household = me.household
        member = me.member
        members = me.members
    }

    func signOut() {
        keychain.delete(tokenAccount)
        user = nil
        household = nil
        member = nil
        members = []
        state = .signedOut
    }
}
