import Foundation
import Observation
import BudgetModels

/// Create/join a household, refresh membership, and mint partner invite codes.
@MainActor
@Observable
final class HouseholdStore {
    private let api: APIClient
    private let session: Session

    var isWorking = false
    var errorMessage: String?
    /// The most recently generated invite, shown for the user to share.
    var latestInvite: InviteResponse?

    init(api: APIClient, session: Session) {
        self.api = api
        self.session = session
    }

    /// Refresh identity + household from `/me`. Signs out on 401.
    func refresh() async {
        do {
            let me: MeResponse = try await api.get("v1/me")
            session.apply(me)
        } catch let error as APIClientError where error.isUnauthorized {
            session.signOut()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createHousehold(name: String, displayName: String) async {
        await perform {
            let me: MeResponse = try await api.post(
                "v1/household",
                body: CreateHouseholdRequest(name: name, memberDisplayName: displayName))
            session.apply(me)
        }
    }

    func join(code: String, displayName: String) async {
        await perform {
            let me: MeResponse = try await api.post(
                "v1/household/join",
                body: JoinHouseholdRequest(code: code, memberDisplayName: displayName))
            session.apply(me)
        }
    }

    func generateInvite() async {
        await perform {
            latestInvite = try await api.post("v1/household/invite", body: Empty())
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            errorMessage = (error as? APIClientError)?.errorDescription ?? error.localizedDescription
        }
    }
}
