import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Mock Plaid transport returning canned JSON, so the sync pipeline is tested
/// deterministically without network (mirrors FlightBag's fixture-injected
/// provider tests).
struct MockPlaidTransport: PlaidTransport {
    func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
        let body: String
        switch url.path {
        case "/sandbox/public_token/create":
            body = #"{"public_token":"public-sandbox-abc"}"#
        case "/item/public_token/exchange":
            body = #"{"access_token":"access-sandbox-xyz","item_id":"item-123"}"#
        case "/accounts/balance/get":
            body = """
            {"accounts":[
              {"account_id":"acc_check","name":"Plaid Checking","official_name":"Plaid Gold Checking",
               "mask":"0000","type":"depository","subtype":"checking",
               "balances":{"current":1200.50,"available":1150.00,"iso_currency_code":"USD"}},
              {"account_id":"acc_card","name":"Plaid Credit Card","mask":"3333","type":"credit",
               "subtype":"credit card","balances":{"current":410.00,"available":null,"iso_currency_code":"USD"}}
            ],"item":{"institution_id":"ins_109508"}}
            """
        case "/transactions/sync":
            body = """
            {"added":[
              {"transaction_id":"tx_1","account_id":"acc_check","amount":52.40,"iso_currency_code":"USD",
               "date":"2026-07-15","name":"Whole Foods Market","merchant_name":"Whole Foods","pending":false,
               "personal_finance_category":{"primary":"FOOD_AND_DRINK","detailed":"FOOD_AND_DRINK_GROCERIES"}},
              {"transaction_id":"tx_2","account_id":"acc_card","amount":13.99,"iso_currency_code":"USD",
               "date":"2026-07-16","name":"Netflix","merchant_name":"Netflix","pending":false,
               "personal_finance_category":{"primary":"ENTERTAINMENT","detailed":"ENTERTAINMENT_STREAMING"}}
            ],"modified":[],"removed":[],"next_cursor":"cursor-1","has_more":false}
            """
        default:
            return (Data("{}".utf8), 404)
        }
        return (Data(body.utf8), 200)
    }
}

@Suite("Plaid sync & account privacy", .serialized)
struct PlaidSyncTests {
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

    @Test("Sandbox link imports accounts; balances map correctly")
    func sandboxLinkImportsAccounts() async throws {
        try await withApp { app in
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Home", memberDisplayName: "Alice")) },
                afterResponse: { res async in #expect(res.status == .ok) })

            var accounts: [Account] = []
            try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    accounts = try res.content.decode([Account].self)
                })
            #expect(accounts.count == 2)
            let checking = try #require(accounts.first { $0.type == .checking })
            #expect(checking.currentBalance == Decimal(string: "1200.50"))
            #expect(checking.mask == "0000")
            let card = try #require(accounts.first { $0.type == .creditCard })
            #expect(card.type.isLiability)
        }
    }

    @Test("A private account is hidden from the partner but not the owner")
    func privateAccountVisibility() async throws {
        try await withApp { app in
            // Alice creates a household, invites Bob, Bob joins.
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Home", memberDisplayName: "Alice")) },
                afterResponse: { _ async in })
            var code = ""
            try await app.testing().test(.POST, "v1/household/invite", headers: bearer(alice.token),
                afterResponse: { res async throws in code = try res.content.decode(InviteResponse.self).code })
            let bob = try await signIn(app, "dev:bob", "Bob")
            try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob")) },
                afterResponse: { _ async in })

            // Alice links accounts (owned by Alice, shared by default).
            var linked: [Account] = []
            try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(alice.token),
                afterResponse: { res async throws in linked = try res.content.decode([Account].self) })
            let card = try #require(linked.first { $0.type == .creditCard })

            // Alice marks the card private.
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { res async in #expect(res.status == .ok) })

            // Bob sees only the shared checking account.
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(bob.token),
                afterResponse: { res async throws in
                    let visible = try res.content.decode([Account].self)
                    #expect(visible.count == 1)
                    #expect(visible.first?.type == .checking)
                })

            // Alice still sees both.
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(try res.content.decode([Account].self).count == 2)
                })
        }
    }

    @Test("Net worth reflects each member's visible accounts")
    func netWorthPerVisibility() async throws {
        try await withApp { app in
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Home", memberDisplayName: "Alice")) },
                afterResponse: { _ async in })
            try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(alice.token),
                afterResponse: { _ async in })

            // Assets 1200.50 (checking) − liabilities 410.00 (card) = 790.50.
            try await app.testing().test(.GET, "v1/networth", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    let nw = try res.content.decode(NetWorthResponse.self)
                    #expect(nw.current.assets == Decimal(string: "1200.50"))
                    #expect(nw.current.liabilities == Decimal(string: "410.00"))
                    #expect(nw.current.net == Decimal(string: "790.50"))
                })
        }
    }

    @Test("Non-owner cannot edit an account")
    func nonOwnerCannotEdit() async throws {
        try await withApp { app in
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Home", memberDisplayName: "Alice")) },
                afterResponse: { _ async in })
            var code = ""
            try await app.testing().test(.POST, "v1/household/invite", headers: bearer(alice.token),
                afterResponse: { res async throws in code = try res.content.decode(InviteResponse.self).code })
            let bob = try await signIn(app, "dev:bob", "Bob")
            try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob")) },
                afterResponse: { _ async in })
            var linked: [Account] = []
            try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(alice.token),
                afterResponse: { res async throws in linked = try res.content.decode([Account].self) })

            // Bob tries to rename Alice's account → forbidden.
            try await app.testing().test(.PATCH, "v1/accounts/\(linked[0].id)", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(name: "Hacked")) },
                afterResponse: { res async in #expect(res.status == .forbidden) })
        }
    }

    // MARK: - Transactions & couples layer

    /// Alice signs in, creates a household (seeds categories), and links a
    /// sandbox item (which pulls transactions).
    private func setupAliceWithData(_ app: Application) async throws -> AuthResponse {
        let alice = try await signIn(app, "dev:alice", "Alice")
        try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
            beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Home", memberDisplayName: "Alice")) },
            afterResponse: { _ async in })
        try await app.testing().test(.POST, "v1/plaid/sandbox-link", headers: bearer(alice.token),
            afterResponse: { _ async in })
        return alice
    }

    private func addBob(_ app: Application, aliceToken: String) async throws -> AuthResponse {
        var code = ""
        try await app.testing().test(.POST, "v1/household/invite", headers: bearer(aliceToken),
            afterResponse: { res async throws in code = try res.content.decode(InviteResponse.self).code })
        let bob = try await signIn(app, "dev:bob", "Bob")
        try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
            beforeRequest: { try $0.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob")) },
            afterResponse: { _ async in })
        return bob
    }

    private func fetchTransactions(_ app: Application, token: String) async throws -> [Transaction] {
        var page: TransactionPage?
        try await app.testing().test(.GET, "v1/transactions", headers: bearer(token),
            afterResponse: { res async throws in page = try res.content.decode(TransactionPage.self) })
        return try #require(page).transactions
    }

    private func fetchCategories(_ app: Application, token: String) async throws -> [BudgetCategory] {
        var response: CategoriesResponse?
        try await app.testing().test(.GET, "v1/categories", headers: bearer(token),
            afterResponse: { res async throws in response = try res.content.decode(CategoriesResponse.self) })
        return try #require(response).categories
    }

    @Test("Linking syncs transactions and auto-categorizes them")
    func transactionsSyncedAndCategorized() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let groceries = try #require(try await fetchCategories(app, token: alice.token).first { $0.name == "Groceries" })
            let txns = try await fetchTransactions(app, token: alice.token)
            #expect(txns.count == 2)
            let wholeFoods = try #require(txns.first { $0.name.contains("Whole Foods") })
            #expect(wholeFoods.amount == Decimal(string: "52.40"))
            #expect(wholeFoods.categoryID == groceries.id)   // auto-categorized
        }
    }

    @Test("A private account hides its transactions from the partner")
    func transactionVisibilityFollowsAccount() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let bob = try await addBob(app, aliceToken: alice.token)

            // Find and privatize the credit-card account (owns the Netflix tx).
            var linked: [Account] = []
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(alice.token),
                afterResponse: { res async throws in linked = try res.content.decode([Account].self) })
            let card = try #require(linked.first { $0.type == .creditCard })
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { _ async in })

            #expect(try await fetchTransactions(app, token: bob.token).count == 1)   // only checking's tx
            #expect(try await fetchTransactions(app, token: alice.token).count == 2)
        }
    }

    @Test("Recategorize, note, and review a transaction")
    func editTransaction() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let tx = try #require(try await fetchTransactions(app, token: alice.token).first)
            let shopping = try #require(try await fetchCategories(app, token: alice.token).first { $0.name == "Shopping" })

            try await app.testing().test(.PATCH, "v1/transactions/\(tx.id)", headers: bearer(alice.token),
                beforeRequest: {
                    try $0.content.encode(UpdateTransactionRequest(categoryID: shopping.id, note: "split with Bob", isReviewed: true))
                }, afterResponse: { res async throws in
                    let updated = try res.content.decode(Transaction.self)
                    #expect(updated.categoryID == shopping.id)
                    #expect(updated.note == "split with Bob")
                    #expect(updated.isReviewed)
                })
        }
    }

    @Test("Comments and emoji reactions on a transaction")
    func commentsAndReactions() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let bob = try await addBob(app, aliceToken: alice.token)
            let tx = try #require(try await fetchTransactions(app, token: alice.token).first { $0.name.contains("Whole Foods") })

            try await app.testing().test(.POST, "v1/transactions/\(tx.id)/comments", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(AddCommentRequest(body: "was this ours?")) },
                afterResponse: { res async in #expect(res.status == .ok) })
            try await app.testing().test(.POST, "v1/transactions/\(tx.id)/comments", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(AddCommentRequest(body: "yeah, groceries")) },
                afterResponse: { res async in #expect(res.status == .ok) })

            // Bob reacts 🎉 (toggle on).
            try await app.testing().test(.POST, "v1/transactions/\(tx.id)/reactions", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(AddReactionRequest(emoji: "🎉")) },
                afterResponse: { res async throws in
                    #expect(try res.content.decode([TransactionReaction].self).count == 1)
                })

            try await app.testing().test(.GET, "v1/transactions/\(tx.id)", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    let detail = try res.content.decode(TransactionDetailResponse.self)
                    #expect(detail.comments.count == 2)
                    #expect(detail.reactions.first?.emoji == "🎉")
                })

            // Toggle the reaction back off.
            try await app.testing().test(.POST, "v1/transactions/\(tx.id)/reactions", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(AddReactionRequest(emoji: "🎉")) },
                afterResponse: { res async throws in
                    #expect(try res.content.decode([TransactionReaction].self).isEmpty)
                })
        }
    }
}
