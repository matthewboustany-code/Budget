import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Account and connection deletion — the "right to delete" path Plaid's data
/// rights review and App Store rules both require.
@Suite("Deletion", .serialized)
struct DeletionTests {

    private func withApp(_ transport: any PlaidTransport,
                         _ test: (Application) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        let app = try await Application.make(.testing)
        do {
            app.appDatabase = try AppDatabase(path: dbPath)
            try await configure(app)
            app.plaidTransport = transport
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

    /// Signs in, creates a household, links a sandbox institution.
    private func setup(_ app: Application, _ dev: String, _ name: String) async throws -> AuthResponse {
        let auth = try await signIn(app, "dev:\(dev)", name)
        try await app.testing().test(.POST, "v1/household", headers: bearer(auth.token),
                                     beforeRequest: { req in
            try req.content.encode(CreateHouseholdRequest(name: "Ours", memberDisplayName: name))
        }, afterResponse: { res async throws in #expect(res.status == .ok) })
        try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(auth.token),
                                     afterResponse: { res async throws in #expect(res.status == .ok) })
        return auth
    }

    private func counts(_ app: Application) async throws -> (accounts: Int, transactions: Int, items: Int) {
        try await app.appDatabase.dbPool.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM accounts") ?? -1,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM transactions") ?? -1,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM plaid_items") ?? -1)
        }
    }

    @Test("Unlinking a connection removes it at Plaid and takes its data with it")
    func unlinkConnection() async throws {
        let transport = RecordingPlaidTransport()
        try await withApp(transport) { app in
            let auth = try await setup(app, "alice", "Alice")

            let before = try await counts(app)
            #expect(before.items == 1)
            #expect(before.accounts > 0)
            #expect(before.transactions > 0)

            var items: [LinkedInstitution] = []
            try await app.testing().test(.GET, "v1/plaid/items", headers: bearer(auth.token),
                                         afterResponse: { res async throws in
                items = try res.content.decode([LinkedInstitution].self)
            })
            #expect(items.count == 1)

            try await app.testing().test(.DELETE, "v1/plaid/items/\(items[0].id)",
                                         headers: bearer(auth.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            // Plaid was actually told to let go — not just a local delete.
            #expect(await transport.calls.contains("/item/remove"))

            // Accounts and transactions cascade with the item.
            let after = try await counts(app)
            #expect(after.items == 0)
            #expect(after.accounts == 0)
            #expect(after.transactions == 0)
        }
    }

    @Test("You cannot unlink someone else's connection")
    func cannotUnlinkOthers() async throws {
        try await withApp(RecordingPlaidTransport()) { app in
            let alice = try await setup(app, "alice", "Alice")
            var aliceItems: [LinkedInstitution] = []
            try await app.testing().test(.GET, "v1/plaid/items", headers: bearer(alice.token),
                                         afterResponse: { res async throws in
                aliceItems = try res.content.decode([LinkedInstitution].self)
            })

            // Bob has his own household entirely.
            let bob = try await setup(app, "bob", "Bob")

            // 404, not 403 — the response must not confirm the item exists.
            let aliceItemID = aliceItems[0].id
            try await app.testing().test(.DELETE, "v1/plaid/items/\(aliceItemID)",
                                         headers: bearer(bob.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .notFound)
            })

            // Alice's data is untouched.
            let stillThere = try await app.appDatabase.dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM plaid_items WHERE id = ?",
                                 arguments: [aliceItemID.uuidString]) ?? 0
            }
            #expect(stillThere == 1)
        }
    }

    @Test("Deleting the last member erases the household and every trace of it")
    func deleteLastMember() async throws {
        let transport = RecordingPlaidTransport()
        try await withApp(transport) { app in
            let auth = try await setup(app, "alice", "Alice")

            try await app.testing().test(.DELETE, "v1/me", headers: bearer(auth.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            #expect(await transport.calls.contains("/item/remove"))

            let remaining = try await app.appDatabase.dbPool.read { db in
                try [
                    "users", "households", "memberships", "plaid_items", "accounts",
                    "transactions", "budgets", "goals", "categories", "net_worth_snapshots",
                ].map { ($0, try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)") ?? -1) }
            }
            for (table, count) in remaining {
                #expect(count == 0, "\(table) should be empty after the last member deletes")
            }

            // The old token must not still work.
            try await app.testing().test(.GET, "v1/me", headers: bearer(auth.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("A departing partner leaves the household and its shared history intact")
    func deleteOneOfTwoMembers() async throws {
        try await withApp(RecordingPlaidTransport()) { app in
            let alice = try await setup(app, "alice", "Alice")

            // Bob joins Alice's household with an invite.
            var code = ""
            try await app.testing().test(.POST, "v1/household/invite", headers: bearer(alice.token),
                                         afterResponse: { res async throws in
                code = try res.content.decode(InviteResponse.self).code
            })
            let bob = try await signIn(app, "dev:bob", "Bob")
            try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
                                         beforeRequest: { req in
                try req.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob"))
            }, afterResponse: { res async throws in #expect(res.status == .ok) })

            // Bob leaves.
            try await app.testing().test(.DELETE, "v1/me", headers: bearer(bob.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })

            // The household survives for Alice, with her data and the shared
            // category tree still in place.
            try await app.testing().test(.GET, "v1/me", headers: bearer(alice.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .ok)
                let me = try res.content.decode(MeResponse.self)
                #expect(me.household != nil)
                #expect(me.members.count == 1)
            })
            let after = try await counts(app)
            #expect(after.items == 1)
            #expect(after.accounts > 0)
        }
    }

    @Test("Deletion still happens when Plaid refuses the removal")
    func deletesEvenIfPlaidFails() async throws {
        let transport = RecordingPlaidTransport(failRemoval: true)
        try await withApp(transport) { app in
            let auth = try await setup(app, "alice", "Alice")

            // The user asked for their data gone; a third party being
            // unavailable must not hold it hostage.
            try await app.testing().test(.DELETE, "v1/me", headers: bearer(auth.token),
                                         afterResponse: { res async throws in
                #expect(res.status == .noContent)
            })
            #expect(await transport.calls.contains("/item/remove"))

            let after = try await counts(app)
            #expect(after.items == 0)
            #expect(after.accounts == 0)
        }
    }
}
