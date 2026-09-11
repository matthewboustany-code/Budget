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
    private(set) var lastLoaded: Date?

    init(api: APIClient) {
        self.api = api
        // Last-known data for the first frame; `load()` refreshes it.
        accounts = api.cached("v1/accounts") ?? []
        netWorth = api.cached("v1/networth")
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedAccounts: [Account] = api.get("v1/accounts")
            async let fetchedNetWorth: NetWorthResponse = api.get("v1/networth")
            accounts = try await fetchedAccounts
            netWorth = try await fetchedNetWorth
            errorMessage = nil
            lastLoaded = Date()
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Linked institutions the signed-in member owns, for the disconnect UI.
    var connections: [LinkedInstitution] = []

    func loadConnections() async {
        do {
            connections = try await api.get("v1/plaid/items")
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
    }

    /// Disconnects an institution: Plaid forgets the Item, and its accounts and
    /// transactions go with it.
    func disconnect(_ connection: LinkedInstitution) async -> Bool {
        do {
            try await api.delete("v1/plaid/items/\(connection.id)")
            connections.removeAll { $0.id == connection.id }
            await load()
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    /// Pull fresh balances and transactions from every bank the caller linked,
    /// right now. Rate-limited server-side; returns false if refused or failed.
    @discardableResult
    func syncNow() async -> Bool {
        do {
            connections = try await api.post("v1/plaid/sync", body: Empty())
            errorMessage = nil
            return true
        } catch {
            errorMessage = friendly(error)
            return false
        }
    }

    /// The most recent successful sync across the caller's connections.
    var lastSyncedAt: Date? { connections.compactMap(\.lastSyncedAt).max() }

    /// Connections that stopped syncing, for the "Needs attention" section.
    var needsAttention: [LinkedInstitution] { connections.filter(\.status.needsAttention) }

    /// A Link token in update mode, to re-authenticate one connection.
    func fetchUpdateLinkToken(for connection: LinkedInstitution) async -> String? {
        do {
            let response: LinkTokenResponse = try await api.post(
                "v1/plaid/items/\(connection.id.uuidString)/update-link-token", body: Empty())
            return response.linkToken
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    /// After update mode succeeds: sync that connection now (which clears its
    /// error server-side), then reload. Update mode repairs the existing item,
    /// so there's no public token to exchange.
    func finishReconnect(_ connection: LinkedInstitution) async {
        do {
            let _: LinkedInstitution = try await api.post(
                "v1/plaid/items/\(connection.id.uuidString)/sync", body: Empty())
            errorMessage = nil
        } catch {
            errorMessage = friendly(error)
        }
        await loadConnections()
        await load()
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
