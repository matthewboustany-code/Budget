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
        case "/accounts/get":
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
        case "/item/remove":
            body = #"{"request_id":"req_removed"}"#
        default:
            return (Data("{}".utf8), 404)
        }
        return (Data(body.utf8), 200)
    }
}

/// Records which Plaid endpoints were hit, so deletion tests can assert that
/// the Item was actually disconnected rather than just dropped locally.
actor RecordingPlaidTransport: PlaidTransport {
    private(set) var calls: [String] = []
    private let inner = MockPlaidTransport()
    /// When true, /item/remove fails — standing in for Plaid being down.
    var failRemoval = false

    init(failRemoval: Bool = false) { self.failRemoval = failRemoval }

    private var exchanges = 0

    func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
        calls.append(url.path)
        if url.path == "/item/remove" && failRemoval {
            return (Data(#"{"error_code":"ITEM_NOT_FOUND"}"#.utf8), 400)
        }
        // plaid_item_id is UNIQUE, so a fixed id would make the second link in
        // a test collide rather than exercise what the test is about.
        if url.path == "/item/public_token/exchange" {
            exchanges += 1
            return (Data(#"{"access_token":"access-sandbox-\#(exchanges)","item_id":"item-\#(exchanges)"}"#.utf8), 200)
        }
        return try await inner.post(url: url, json: json)
    }
}

/// Serves a pending charge on the first `/transactions/sync`, then the page in
/// which Plaid posts it: the pending id in `removed`, a new id in `added`.
actor PendingThenPostedTransport: PlaidTransport {
    private let inner = MockPlaidTransport()
    private var syncs = 0

    func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
        guard url.path == "/transactions/sync" else { return try await inner.post(url: url, json: json) }
        syncs += 1
        let body = syncs == 1 ? """
            {"added":[{"transaction_id":"tx_pending","account_id":"acc_check","amount":20.00,
              "date":"2026-07-20","name":"Corner Cafe","merchant_name":"Corner Cafe","pending":true}],
             "modified":[],"removed":[],"next_cursor":"cursor-1","has_more":false}
            """ : """
            {"added":[{"transaction_id":"tx_posted","account_id":"acc_check","amount":24.00,
              "date":"2026-07-21","name":"Corner Cafe","merchant_name":"Corner Cafe","pending":false,
              "pending_transaction_id":"tx_pending"}],
             "modified":[],"removed":[{"transaction_id":"tx_pending"}],"next_cursor":"cursor-2","has_more":false}
            """
        return (Data(body.utf8), 200)
    }
}

/// Fails /transactions/sync with ITEM_LOGIN_REQUIRED while `broken`, and keeps
/// the last /link/token/create body so update mode's request can be checked.
actor ItemHealthTransport: PlaidTransport {
    private let inner = MockPlaidTransport()
    private(set) var broken = false
    private(set) var lastLinkTokenBody: Data?

    func setBroken(_ value: Bool) { broken = value }

    func post(url: URL, json: Data) async throws -> (data: Data, status: Int) {
        switch url.path {
        case "/link/token/create":
            lastLinkTokenBody = json
            return (Data(#"{"link_token":"link-sandbox-update","expiration":null}"#.utf8), 200)
        case "/transactions/sync" where broken:
            return (Data(#"{"error_type":"ITEM_ERROR","error_code":"ITEM_LOGIN_REQUIRED","error_message":"login required"}"#.utf8), 400)
        default:
            return try await inner.post(url: url, json: json)
        }
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

    @Test("The net-worth series counts only the caller's visible accounts")
    func netWorthSeriesFollowsVisibility() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let bob = try await addBob(app, aliceToken: alice.token)
            var linked: [Account] = []
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(alice.token),
                afterResponse: { res async throws in linked = try res.content.decode([Account].self) })
            let card = try #require(linked.first { $0.type == .creditCard })
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { _ async in })
            try await NetWorthSnapshotCommand.snapshotAll(app)

            // Bob can't see the card, so neither his series nor his current
            // includes its 410 liability — no step at the end of his chart.
            try await app.testing().test(.GET, "v1/networth", headers: bearer(bob.token),
                afterResponse: { res async throws in
                    let nw = try res.content.decode(NetWorthResponse.self)
                    let last = try #require(nw.series.last)
                    #expect(last.net == nw.current.net)
                    #expect(last.net == Decimal(string: "1200.50"))
                })
            try await app.testing().test(.GET, "v1/networth", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    let nw = try res.content.decode(NetWorthResponse.self)
                    #expect(nw.series.last?.net == Decimal(string: "790.50"))
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

    private func reviewSummary(_ app: Application, token: String) async throws -> ReviewSummary {
        var summary: ReviewSummary?
        try await app.testing().test(.GET, "v1/transactions/review-summary", headers: bearer(token),
            afterResponse: { res async throws in summary = try res.content.decode(ReviewSummary.self) })
        return try #require(summary)
    }

    private func fetchTransactions(_ app: Application, token: String, query: String) async throws -> [Transaction] {
        var page: TransactionPage?
        try await app.testing().test(.GET, "v1/transactions?\(query)", headers: bearer(token),
            afterResponse: { res async throws in page = try res.content.decode(TransactionPage.self) })
        return try #require(page).transactions
    }

    @Test("Unreviewed and uncategorized filters, and the review summary, track edits")
    func reviewInboxFilters() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let txns = try await fetchTransactions(app, token: alice.token)
            #expect(try await reviewSummary(app, token: alice.token) == ReviewSummary(unreviewed: 2, uncategorized: 0))
            #expect(try await fetchTransactions(app, token: alice.token, query: "unreviewed=1").count == 2)
            #expect(try await fetchTransactions(app, token: alice.token, query: "uncategorized=1").isEmpty)

            let first = txns[0], second = txns[1]
            try await app.testing().test(.PATCH, "v1/transactions/\(first.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateTransactionRequest(isReviewed: true)) },
                afterResponse: { _ async in })
            try await app.testing().test(.PATCH, "v1/transactions/\(second.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(["clearCategory": true]) },
                afterResponse: { _ async in })

            #expect(try await reviewSummary(app, token: alice.token) == ReviewSummary(unreviewed: 1, uncategorized: 1))
            #expect(try await fetchTransactions(app, token: alice.token, query: "unreviewed=1").map(\.id) == [second.id])
            #expect(try await fetchTransactions(app, token: alice.token, query: "uncategorized=1").map(\.id) == [second.id])
            // Anything but "1" is no filter.
            #expect(try await fetchTransactions(app, token: alice.token, query: "unreviewed=0").count == 2)
        }
    }

    @Test("The review summary counts only the caller's visible transactions")
    func reviewSummaryFollowsVisibility() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let bob = try await addBob(app, aliceToken: alice.token)
            var linked: [Account] = []
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(alice.token),
                afterResponse: { res async throws in linked = try res.content.decode([Account].self) })
            let card = try #require(linked.first { $0.type == .creditCard })
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { _ async in })
            #expect(try await reviewSummary(app, token: bob.token).unreviewed == 1)
            #expect(try await reviewSummary(app, token: alice.token).unreviewed == 2)
        }
    }

    @Test("Split amounts must add up to the transaction total")
    func splitsMustBalance() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let wholeFoods = try #require(try await fetchTransactions(app, token: alice.token)
                .first { $0.name.contains("Whole Foods") })   // amount 52.40
            let cats = try await fetchCategories(app, token: alice.token)
            let groceries = try #require(cats.first { $0.name == "Groceries" })
            let shopping = try #require(cats.first { $0.name == "Shopping" })

            // Unbalanced (40 + 10 = 50 ≠ 52.40) is rejected.
            try await app.testing().test(.PATCH, "v1/transactions/\(wholeFoods.id)", headers: bearer(alice.token),
                beforeRequest: {
                    try $0.content.encode(UpdateTransactionRequest(splits: [
                        TransactionSplit(id: UUID(), categoryID: groceries.id, amount: 40),
                        TransactionSplit(id: UUID(), categoryID: shopping.id, amount: 10),
                    ]))
                }, afterResponse: { res async in #expect(res.status == .badRequest) })

            // Balanced (40.00 + 12.40 = 52.40) is accepted.
            try await app.testing().test(.PATCH, "v1/transactions/\(wholeFoods.id)", headers: bearer(alice.token),
                beforeRequest: {
                    try $0.content.encode(UpdateTransactionRequest(splits: [
                        TransactionSplit(id: UUID(), categoryID: groceries.id, amount: Decimal(string: "40.00")!),
                        TransactionSplit(id: UUID(), categoryID: shopping.id, amount: Decimal(string: "12.40")!),
                    ]))
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(Transaction.self).splits.count == 2)
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

    // MARK: - Item health

    private func postWebhook(_ app: Application, _ json: String) async throws {
        try await app.testing().test(.POST, "v1/plaid/webhook",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.body = .init(string: json)
            }, afterResponse: { res async in #expect(res.status == .ok) })
    }

    private func connections(_ app: Application, token: String) async throws -> [LinkedInstitution] {
        var out: [LinkedInstitution] = []
        try await app.testing().test(.GET, "v1/plaid/items", headers: bearer(token),
            afterResponse: { res async throws in out = try res.content.decode([LinkedInstitution].self) })
        return out
    }

    @Test("ITEM webhooks set a connection's health, and LOGIN_REPAIRED clears it")
    func itemWebhooksSetHealth() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            #expect(try await connections(app, token: alice.token).first?.status == .ok)

            try await postWebhook(app, #"{"webhook_type":"ITEM","webhook_code":"ERROR","item_id":"item-123","error":{"error_code":"ITEM_LOGIN_REQUIRED"}}"#)
            let broken = try #require(try await connections(app, token: alice.token).first)
            #expect(broken.status == .error)
            #expect(broken.errorCode == "ITEM_LOGIN_REQUIRED")

            try await postWebhook(app, #"{"webhook_type":"ITEM","webhook_code":"PENDING_EXPIRATION","item_id":"item-123"}"#)
            #expect(try await connections(app, token: alice.token).first?.status == .pendingExpiration)

            try await postWebhook(app, #"{"webhook_type":"ITEM","webhook_code":"LOGIN_REPAIRED","item_id":"item-123"}"#)
            let repaired = try #require(try await connections(app, token: alice.token).first)
            #expect(repaired.status == .ok)
            #expect(repaired.errorCode == nil)
        }
    }

    @Test("A sync Plaid rejects for login flags the item; a good sync clears it")
    func failedSyncFlagsItem() async throws {
        try await withApp { app in
            let transport = ItemHealthTransport()
            app.plaidTransport = transport
            let alice = try await setupAliceWithData(app)
            let item = try #require(try await connections(app, token: alice.token).first)
            #expect(item.lastSyncedAt != nil)   // the link's initial sync succeeded

            await transport.setBroken(true)
            try await postWebhook(app, #"{"webhook_type":"TRANSACTIONS","item_id":"item-123"}"#)
            let flagged = try #require(try await connections(app, token: alice.token).first)
            #expect(flagged.status == .error)
            #expect(flagged.errorCode == "ITEM_LOGIN_REQUIRED")

            // The owner reconnects; the app then asks for an immediate sync.
            await transport.setBroken(false)
            try await app.testing().test(.POST, "v1/plaid/items/\(item.id)/sync", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let fresh = try res.content.decode(LinkedInstitution.self)
                    #expect(fresh.status == .ok)
                    #expect(fresh.errorCode == nil)
                })
        }
    }

    @Test("Update-mode link tokens carry the access token, no products, and are owner-only")
    func updateModeLinkToken() async throws {
        try await withApp { app in
            let transport = ItemHealthTransport()
            app.plaidTransport = transport
            let alice = try await setupAliceWithData(app)
            let bob = try await addBob(app, aliceToken: alice.token)
            let item = try #require(try await connections(app, token: alice.token).first)

            try await app.testing().test(.POST, "v1/plaid/items/\(item.id)/update-link-token", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(LinkTokenResponse.self).linkToken == "link-sandbox-update")
                })
            let body = try #require(await transport.lastLinkTokenBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["products"] == nil)
            #expect(json["access_token"] as? String == "access-sandbox-xyz")

            // The partner can't mint one for Alice's connection — and gets 404, not 403.
            try await app.testing().test(.POST, "v1/plaid/items/\(item.id)/update-link-token", headers: bearer(bob.token),
                afterResponse: { res async in #expect(res.status == .notFound) })
        }
    }

    @Test("Manual accounts: create, set a balance, add and delete transactions; Plaid rows stay bank-owned")
    func manualAccounts() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let bob = try await addBob(app, aliceToken: alice.token)

            var created: Account?
            try await app.testing().test(.POST, "v1/accounts", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateManualAccountRequest(name: "Wallet", type: .cash, currentBalance: 80)) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    created = try res.content.decode(Account.self)
                })
            let wallet = try #require(created)
            #expect(wallet.isManual)

            // Net worth counts it: 1200.50 checking − 410 card + 80 cash.
            try await app.testing().test(.GET, "v1/networth", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(try res.content.decode(NetWorthResponse.self).current.net == Decimal(string: "870.50"))
                })

            // Balances: settable on a manual account, never on a linked one.
            try await app.testing().test(.PATCH, "v1/accounts/\(wallet.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(currentBalance: 95)) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(Account.self).currentBalance == 95)
                })
            var linked: [Account] = []
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(alice.token),
                afterResponse: { res async throws in linked = try res.content.decode([Account].self) })
            let checking = try #require(linked.first { $0.type == .checking && !$0.isManual })
            try await app.testing().test(.PATCH, "v1/accounts/\(checking.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(currentBalance: 1)) },
                afterResponse: { res async in #expect(res.status == .badRequest) })

            // Transactions: on the wallet yes; on a linked account no; the partner no.
            var added: BudgetModels.Transaction?
            try await app.testing().test(.POST, "v1/transactions", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateTransactionRequest(
                    accountID: wallet.id, amount: 12, date: Date(), name: "Farmers market")) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    added = try res.content.decode(BudgetModels.Transaction.self)
                })
            let manualTx = try #require(added)
            try await app.testing().test(.POST, "v1/transactions", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateTransactionRequest(
                    accountID: checking.id, amount: 5, date: Date(), name: "Sneaky")) },
                afterResponse: { res async in #expect(res.status == .badRequest) })
            try await app.testing().test(.POST, "v1/transactions", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(CreateTransactionRequest(
                    accountID: wallet.id, amount: 5, date: Date(), name: "Not mine")) },
                afterResponse: { res async in #expect(res.status == .forbidden) })
            #expect(try await fetchTransactions(app, token: alice.token).contains { $0.id == manualTx.id })

            // Delete: the manual one goes; a Plaid one can't.
            try await app.testing().test(.DELETE, "v1/transactions/\(manualTx.id)", headers: bearer(alice.token),
                afterResponse: { res async in #expect(res.status == .noContent) })
            let remaining = try await fetchTransactions(app, token: alice.token)
            #expect(!remaining.contains { $0.id == manualTx.id })
            let plaidTx = try #require(remaining.first { $0.plaidTransactionID != nil })
            try await app.testing().test(.DELETE, "v1/transactions/\(plaidTx.id)", headers: bearer(alice.token),
                afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Sync now pulls the caller's connections, and is rate-limited per user")
    func syncNowIsRateLimited() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            for _ in 0..<6 {
                try await app.testing().test(.POST, "v1/plaid/sync", headers: bearer(alice.token),
                    afterResponse: { res async throws in
                        #expect(res.status == .ok)
                        let synced = try res.content.decode([LinkedInstitution].self)
                        #expect(synced.count == 1)
                        #expect(synced.first?.status == .ok)
                        #expect(synced.first?.lastSyncedAt != nil)
                    })
            }
            try await app.testing().test(.POST, "v1/plaid/sync", headers: bearer(alice.token),
                afterResponse: { res async in
                    #expect(res.status == .tooManyRequests)
                    #expect(res.headers.first(name: .retryAfter) != nil)
                })

            // The limit is per user: the partner still gets through.
            let bob = try await addBob(app, aliceToken: alice.token)
            try await app.testing().test(.POST, "v1/plaid/sync", headers: bearer(bob.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode([LinkedInstitution].self).isEmpty)   // Bob owns none
                })
        }
    }

    @Test("Paging doesn't skip or repeat rows when a sync lands mid-scroll")
    func keysetPaginationSurvivesInserts() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let existing = try #require(try await fetchTransactions(app, token: alice.token).first)
            func insert(_ name: String, daysAgo: Int) async throws {
                try await app.appDatabase.dbPool.write { db in
                    try TransactionStore.upsertPlaid(BudgetModels.Transaction(
                        id: UUID(), householdID: existing.householdID, accountID: existing.accountID,
                        ownerMemberID: existing.ownerMemberID, amount: 1,
                        date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
                        name: name, plaidTransactionID: "page-\(name)", createdAt: Date()), db)
                }
            }
            for i in 0..<5 { try await insert("Old \(i)", daysAgo: 10 + i) }
            func page(_ cursor: String?) async throws -> TransactionPage {
                var out: TransactionPage?
                let q = cursor.map { "&cursor=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)" } ?? ""
                try await app.testing().test(.GET, "v1/transactions?limit=3\(q)", headers: bearer(alice.token),
                    afterResponse: { res async throws in
                        #expect(res.status == .ok)
                        out = try res.content.decode(TransactionPage.self)
                    })
                return try #require(out)
            }
            let first = try await page(nil)
            // A newer transaction arrives between pages; with an offset the next
            // page would start one row early and repeat the last row seen.
            try await insert("Brand new", daysAgo: 0)
            var seen = first.transactions.map(\.id)
            var cursor = first.nextCursor
            while let c = cursor {
                let next = try await page(c)
                seen += next.transactions.map(\.id)
                cursor = next.nextCursor
            }
            #expect(seen.count == Set(seen).count)   // no repeats
            #expect(seen.count == 7)                 // 2 fixtures + 5 old; the new one is above page 1
        }
    }

    @Test("Search treats % and _ literally")
    func searchEscapesWildcards() async throws {
        try await withApp { app in
            let alice = try await setupAliceWithData(app)
            let existing = try #require(try await fetchTransactions(app, token: alice.token).first)
            try await app.appDatabase.dbPool.write { db in
                for name in ["100% Juice", "1000 Things", "A_B Store", "AxB Store"] {
                    let tx = BudgetModels.Transaction(
                        id: UUID(), householdID: existing.householdID, accountID: existing.accountID,
                        ownerMemberID: existing.ownerMemberID, amount: 1, date: Date(), name: name,
                        plaidTransactionID: "search-\(name)", createdAt: Date())
                    try TransactionStore.upsertPlaid(tx, db)
                }
            }
            func search(_ q: String) async throws -> [String] {
                var page: TransactionPage?
                try await app.testing().test(.GET, "v1/transactions?search=\(q)", headers: bearer(alice.token),
                    afterResponse: { res async throws in page = try res.content.decode(TransactionPage.self) })
                return try #require(page).transactions.map(\.name)
            }
            #expect(try await search("100%25") == ["100% Juice"])
            #expect(try await search("A_B") == ["A_B Store"])
        }
    }

    @Test("A pending charge that posts keeps its row, edits, and comments")
    func pendingToPostedKeepsEdits() async throws {
        try await withApp { app in
            app.plaidTransport = PendingThenPostedTransport()
            let alice = try await setupAliceWithData(app)
            let pending = try #require(try await fetchTransactions(app, token: alice.token).first)
            #expect(pending.status == .pending)
            let dining = try #require(try await fetchCategories(app, token: alice.token).first { $0.name == "Shopping" })

            try await app.testing().test(.PATCH, "v1/transactions/\(pending.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateTransactionRequest(categoryID: dining.id, note: "tip")) },
                afterResponse: { res async in #expect(res.status == .ok) })
            try await app.testing().test(.POST, "v1/transactions/\(pending.id)/comments", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(AddCommentRequest(body: "coffee date")) },
                afterResponse: { res async in #expect(res.status == .ok) })

            // Plaid posts it: the webhook (unsigned in dev mode) runs the second sync page.
            try await app.testing().test(.POST, "v1/plaid/webhook",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(string: #"{"webhook_type":"TRANSACTIONS","item_id":"item-123"}"#)
                }, afterResponse: { res async in #expect(res.status == .ok) })

            let after = try await fetchTransactions(app, token: alice.token)
            #expect(after.count == 1)
            let posted = try #require(after.first)
            #expect(posted.id == pending.id)
            #expect(posted.status == .posted)
            #expect(posted.amount == 24)
            #expect(posted.categoryID == dining.id)
            #expect(posted.note == "tip")
            #expect(posted.plaidTransactionID == "tx_posted")
            try await app.testing().test(.GET, "v1/transactions/\(pending.id)", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(try res.content.decode(TransactionDetailResponse.self).comments.count == 1)
                })
        }
    }
}
