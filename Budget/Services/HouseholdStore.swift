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
    /// The last `/me` failed for a reason other than auth. The session keeps
    /// its cached household, so the app stays usable and shows a banner.
    private(set) var isOffline = false

    init(api: APIClient, session: Session) {
        self.api = api
        self.session = session
    }

    /// Refresh identity + household from `/me`. A 401 signs out via the
    /// client's `onUnauthorized`; any other failure keeps the cached household.
    func refresh() async {
        do {
            let me: MeResponse = try await api.get("v1/me")
            session.apply(me)
            isOffline = false
        } catch let error as APIClientError where error.isUnauthorized {
            isOffline = false
        } catch {
            isOffline = true
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
