import Foundation
import Observation
import BudgetModels

/// Accounts + net worth for the current household, and the Plaid linking calls.
@MainActor
@Observable
final class AccountStore {
    private let api: APIClient

    var accounts: [Account] = []
    var netWorth: NetWorthResponse?
    var isLoading = false
    var isLinking = false
    var errorMessage: String?

    init(api: APIClient) { self.api = api }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedAccounts: [Account] = api.get("v1/accounts")
            async let fetchedNetWorth: NetWorthResponse = api.get("v1/networth")
            accounts = try await fetchedAccounts
            netWorth = try await fetchedNetWorth
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Fetch a Plaid Link token to open Link on the device.
    func fetchLinkToken() async -> String? {
        do {
            let response: LinkTokenResponse = try await api.post("v1/plaid/link-token", body: Empty())
            return response.linkToken
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    /// Exchange a public token from Link and reload.
    func exchange(publicToken: String, institutionName: String?) async {
        isLinking = true
        defer { isLinking = false }
        do {
            let _: [Account] = try await api.post(
                "v1/plaid/exchange",
                body: ExchangePublicTokenRequest(publicToken: publicToken,
                                                 institutionName: institutionName, visibility: .shared))
            await load()
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// DEBUG/dev: link a Plaid sandbox institution without the Link UI.
    func linkSandbox() async {
        isLinking = true
        defer { isLinking = false }
        do {
            let _: [Account] = try await api.post(
                "v1/plaid/sandbox-link",
                body: SandboxLinkRequest(institutionName: "First Platypus Bank", visibility: .shared))
            await load()
        } catch {
            errorMessage = friendly(error)
        }
    }

    func update(_ account: Account, name: String? = nil,
                visibility: Visibility? = nil, isHidden: Bool? = nil) async {
        do {
            let updated: Account = try await api.patch(
                "v1/accounts/\(account.id.uuidString)",
                body: UpdateAccountRequest(name: name, visibility: visibility, isHidden: isHidden))
            if let index = accounts.firstIndex(where: { $0.id == updated.id }) {
                accounts[index] = updated
            }
            netWorth = try? await api.get("v1/networth")
        } catch {
            errorMessage = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        (error as? APIClientError)?.errorDescription ?? error.localizedDescription
    }
}
