import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Per-account balance history (4.8). Snapshots are written by the nightly
/// command, so the tests drive that store directly rather than waiting a day.
@Suite("Account balance history", .serialized)
struct AccountHistoryTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        let app = try await Application.make(.testing)
        do {
            app.appDatabase = try AppDatabase(path: dbPath)
            try await configure(app)
            app.plaidTransport = MockPlaidTransport()
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            cleanup(dbPath)
            throw error
        }
        try await app.asyncShutdown()
        cleanup(dbPath)
    }

    private func cleanup(_ path: String) {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    private func bearer(_ token: String) -> HTTPHeaders {
        var h = HTTPHeaders(); h.add(name: .authorization, value: "Bearer \(token)"); return h
    }

    private func signIn(_ app: Application, _ token: String, _ name: String) async throws -> AuthResponse {
        var out: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/apple", beforeRequest: { req in
            try req.content.encode(AppleSignInRequest(identityToken: token, fullName: name))
        }, afterResponse: { res async throws in out = try res.content.decode(AuthResponse.self) })
        return try #require(out)
    }

    private func makeAccount(_ app: Application, token: String, name: String,
                             visibility: Visibility) async throws -> Account {
        var out: Account?
        try await app.testing().test(.POST, "v1/accounts", headers: bearer(token),
            beforeRequest: {
                try $0.content.encode(CreateManualAccountRequest(name: name, type: .checking,
                                                                 visibility: visibility,
                                                                 currentBalance: 100))
            },
            afterResponse: { res async throws in out = try res.content.decode(Account.self) })
        return try #require(out)
    }

    @Test("History returns the account's snapshots, oldest first, bounded by days")
    func historyRange() async throws {
        try await withApp { app in
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "H", memberDisplayName: "Alice")) },
                afterResponse: { _ async in })
            let checking = try await makeAccount(app, token: alice.token, name: "Checking", visibility: .shared)

            // Three snapshots: 200 days ago (outside a 90-day window), and two recent.
            let store = NetWorthStore(db: app.appDatabase.dbPool)
            let calendar = Calendar.current
            for (daysAgo, balance) in [(200, Money(10)), (5, Money(250)), (1, Money(300))] {
                var dated = checking
                dated.currentBalance = balance
                let day = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: Date()))
                try await store.snapshotAccounts([dated], date: day)
            }

            try await app.testing().test(.GET, "v1/accounts/\(checking.id)/balances",
                headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(AccountBalanceHistoryResponse.self)
                    #expect(body.account.id == checking.id)
                    // Default window is 90 days, so the 200-day-old row is out.
                    #expect(body.points.map(\.current) == [250, 300])
                    #expect(body.points[0].date < body.points[1].date)
                })

            // A wider window reaches the old row.
            try await app.testing().test(.GET, "v1/accounts/\(checking.id)/balances?days=365",
                headers: bearer(alice.token),
                afterResponse: { res async throws in
                    let body = try res.content.decode(AccountBalanceHistoryResponse.self)
                    #expect(body.points.map(\.current) == [10, 250, 300])
                })
        }
    }

    @Test("A partner's private account's history is 404, not 403")
    func privateHistoryHidden() async throws {
        try await withApp { app in
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "H", memberDisplayName: "Alice")) },
                afterResponse: { _ async in })
            var code = ""
            try await app.testing().test(.POST, "v1/household/invite", headers: bearer(alice.token),
                afterResponse: { res async throws in code = try res.content.decode(InviteResponse.self).code })
            let bob = try await signIn(app, "dev:bob", "Bob")
            try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob")) },
                afterResponse: { _ async in })

            let secret = try await makeAccount(app, token: alice.token, name: "Secret", visibility: .private)

            try await app.testing().test(.GET, "v1/accounts/\(secret.id)/balances",
                headers: bearer(bob.token),
                afterResponse: { res async in #expect(res.status == .notFound) })
            // The owner still sees it.
            try await app.testing().test(.GET, "v1/accounts/\(secret.id)/balances",
                headers: bearer(alice.token),
                afterResponse: { res async in #expect(res.status == .ok) })
        }
    }
}
