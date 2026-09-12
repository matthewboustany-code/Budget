import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// The partner activity feed (v1.1 §5.1): what the *other* member did, and
/// nothing they weren't allowed to see.
@Suite("Partner activity feed", .serialized)
struct ActivityFeedTests {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        let app = try await Application.make(.testing)
        do {
            app.appDatabase = try AppDatabase(path: dbPath)   // inject before configure
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

    /// Alice owns a household with two linked accounts and two transactions;
    /// Bob has joined it.
    private func couple(_ app: Application) async throws -> (alice: AuthResponse, bob: AuthResponse, accounts: [Account]) {
        let alice = try await signIn(app, "dev:alice", "Alice")
        try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
            beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Home", memberDisplayName: "Alice")) },
            afterResponse: { res async in #expect(res.status == .ok) })
        var code = ""
        try await app.testing().test(.POST, "v1/household/invite", headers: bearer(alice.token),
            afterResponse: { res async throws in code = try res.content.decode(InviteResponse.self).code })
        let bob = try await signIn(app, "dev:bob", "Bob")
        try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
            beforeRequest: { try $0.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob")) },
            afterResponse: { res async in #expect(res.status == .ok) })
        var accounts: [Account] = []
        try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(alice.token),
            afterResponse: { res async throws in accounts = try res.content.decode([Account].self) })
        return (alice, bob, accounts)
    }

    private func transactions(_ app: Application, token: String) async throws -> [Transaction] {
        var out: [Transaction] = []
        try await app.testing().test(.GET, "v1/transactions", headers: bearer(token),
            afterResponse: { res async throws in out = try res.content.decode(TransactionPage.self).transactions })
        return out
    }

    private func feed(_ app: Application, token: String, since: Date? = nil) async throws -> [ActivityEvent] {
        var path = "v1/activity"
        if let since { path += "?since=\(ISO8601DateFormatter().string(from: since))" }
        var out: [ActivityEvent] = []
        try await app.testing().test(.GET, path, headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                out = try res.content.decode(ActivityFeedResponse.self).events
            })
        return out
    }

    private func comment(_ app: Application, token: String, on tx: Transaction, _ body: String) async throws {
        try await app.testing().test(.POST, "v1/transactions/\(tx.id)/comments", headers: bearer(token),
            beforeRequest: { try $0.content.encode(AddCommentRequest(body: body)) },
            afterResponse: { res async in #expect(res.status == .ok) })
    }

    @Test("The feed carries the partner's comments and reactions, never your own")
    func partnerOnly() async throws {
        try await withApp { app in
            let (alice, bob, _) = try await couple(app)
            let wholeFoods = try #require(try await transactions(app, token: alice.token)
                .first { $0.name.contains("Whole Foods") })

            try await comment(app, token: alice.token, on: wholeFoods, "was this ours?")
            try await comment(app, token: bob.token, on: wholeFoods, "yeah, groceries")
            try await app.testing().test(.POST, "v1/transactions/\(wholeFoods.id)/reactions",
                headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(AddReactionRequest(emoji: "🎉")) },
                afterResponse: { res async in #expect(res.status == .ok) })

            // Alice sees Bob's comment and Bob's reaction — not her own comment.
            let aliceFeed = try await feed(app, token: alice.token)
            #expect(aliceFeed.count == 2)
            #expect(aliceFeed.allSatisfy { $0.memberName == "Bob" })
            let aliceComment = try #require(aliceFeed.first { $0.kind == .comment })
            #expect(aliceComment.body == "yeah, groceries")
            #expect(aliceComment.transactionID == wholeFoods.id)
            #expect(aliceComment.transactionName == wholeFoods.name)
            #expect(aliceComment.transactionAmount == wholeFoods.amount)
            #expect(aliceFeed.contains { $0.kind == .reaction && $0.emoji == "🎉" })

            // Bob sees only Alice's comment.
            let bobFeed = try await feed(app, token: bob.token)
            #expect(bobFeed.count == 1)
            #expect(bobFeed.first?.memberName == "Alice")
            #expect(bobFeed.first?.body == "was this ours?")
        }
    }

    @Test("Chatter on a private account never reaches the partner's feed")
    func privateAccountChatterHidden() async throws {
        try await withApp { app in
            let (alice, bob, accounts) = try await couple(app)
            let card = try #require(accounts.first { $0.type == .creditCard })
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { res async in #expect(res.status == .ok) })

            let aliceTxs = try await transactions(app, token: alice.token)
            let netflix = try #require(aliceTxs.first { $0.name.contains("Netflix") })      // on the private card
            let wholeFoods = try #require(aliceTxs.first { $0.name.contains("Whole Foods") })
            try await comment(app, token: alice.token, on: netflix, "my subscription")
            try await comment(app, token: alice.token, on: wholeFoods, "our groceries")

            // Bob gets the shared one only — otherwise the feed would leak the
            // merchant name of a charge the transactions list hides.
            let bobFeed = try await feed(app, token: bob.token)
            #expect(bobFeed.count == 1)
            #expect(bobFeed.first?.transactionName.contains("Whole Foods") == true)
            #expect(!bobFeed.contains { $0.transactionName.contains("Netflix") })
        }
    }

    @Test("since= returns only what arrived after the client's last visit")
    func sinceFilter() async throws {
        try await withApp { app in
            let (alice, bob, _) = try await couple(app)
            let wholeFoods = try #require(try await transactions(app, token: alice.token)
                .first { $0.name.contains("Whole Foods") })
            try await comment(app, token: bob.token, on: wholeFoods, "first")

            let all = try await feed(app, token: alice.token)
            #expect(all.count == 1)
            let newest = try #require(all.first?.createdAt)

            // Marked read up to the newest event: nothing left unread. (`since`
            // is strictly exclusive — timestamps are second-resolution, so an
            // inclusive bound would re-show what the user just read.)
            #expect(try await feed(app, token: alice.token, since: newest).isEmpty)
            // And an old bound still returns everything.
            #expect(try await feed(app, token: alice.token,
                                   since: newest.addingTimeInterval(-3600)).count == 1)
        }
    }
}
