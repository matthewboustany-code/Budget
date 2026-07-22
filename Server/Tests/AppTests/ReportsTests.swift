import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Cash flow + spending reports (P6). Builds on the Plaid mock's July 2026
/// fixtures (Whole Foods 52.40 → Groceries on checking, Netflix 13.99 →
/// Entertainment on credit card); extra history is seeded straight through
/// the DB pool with explicit categories.
@Suite("Reports", .serialized)
struct ReportsTests {
    private let july = Month(year: 2026, month: 7)

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

    private func setupAlice(_ app: Application) async throws -> AuthResponse {
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

    private func accounts(_ app: Application, token: String) async throws -> [Account] {
        var out: [Account] = []
        try await app.testing().test(.GET, "v1/accounts", headers: bearer(token),
            afterResponse: { res async throws in out = try res.content.decode([Account].self) })
        return out
    }

    private func category(_ app: Application, token: String, named name: String) async throws -> BudgetCategory {
        var tree: CategoriesResponse?
        try await app.testing().test(.GET, "v1/categories", headers: bearer(token),
            afterResponse: { res async throws in tree = try res.content.decode(CategoriesResponse.self) })
        let match = tree?.categories.first { $0.name == name }
        return try #require(match)
    }

    private func seed(_ app: Application, account: Account, name: String, amount: Money,
                      day: Int, category: UUID?) async throws {
        // Midday UTC so the date stays inside July in any plausible local zone
        // (the report routes bucket months in the server's local calendar).
        var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = day
        comps.hour = 12
        comps.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        try await app.appDatabase.dbPool.write { db in
            let tx = BudgetModels.Transaction(
                id: UUID(), householdID: account.householdID, accountID: account.id,
                ownerMemberID: account.ownerMemberID, amount: amount, date: date,
                name: name, merchantName: name, categoryID: category,
                plaidTransactionID: "seed-\(name)-\(day)", createdAt: date)
            try TransactionStore.upsertPlaid(tx, db)
        }
    }

    private func julyCashFlow(_ app: Application, token: String) async throws -> CashFlowSummary {
        var response: CashFlowReportResponse?
        try await app.testing().test(.GET, "v1/reports/cashflow?months=24", headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(CashFlowReportResponse.self)
            })
        let match = response?.months.first { $0.month == july }
        return try #require(match)
    }

    private func julySpending(_ app: Application, token: String) async throws -> SpendingReportResponse {
        var response: SpendingReportResponse?
        try await app.testing().test(.GET, "v1/reports/spending?month=2026-07", headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(SpendingReportResponse.self)
            })
        return try #require(response)
    }

    @Test("Cash flow separates income from spending and skips transfers")
    func cashFlowExcludesTransfers() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            let paycheck = try await category(app, token: alice.token, named: "Paycheck")
            let transfer = try await category(app, token: alice.token, named: "Transfer")

            try await seed(app, account: checking, name: "Acme Payroll", amount: -3000,
                           day: 1, category: paycheck.id)
            // A 500 sweep to savings — must not count as spending or income.
            try await seed(app, account: checking, name: "To Savings", amount: 500,
                           day: 2, category: transfer.id)

            let cf = try await julyCashFlow(app, token: alice.token)
            #expect(cf.income == Decimal(3000))
            // Fixtures: Whole Foods 52.40 + Netflix 13.99 — no transfer.
            #expect(cf.expenses == Decimal(string: "66.39"))
            #expect(cf.net == Decimal(string: "2933.61"))
        }
    }

    @Test("Spending report ranks categories, attaches budgets, skips transfers")
    func spendingReport() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            let transfer = try await category(app, token: alice.token, named: "Transfer")
            let groceries = try await category(app, token: alice.token, named: "Groceries")
            try await seed(app, account: checking, name: "To Savings", amount: 500,
                           day: 2, category: transfer.id)
            try await app.testing().test(.PUT, "v1/budgets/\(groceries.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(SetBudgetRequest(month: july, amount: 400)) },
                afterResponse: { _ async in })

            let report = try await julySpending(app, token: alice.token)
            #expect(report.entries.first?.categoryName == "Groceries")   // 52.40 > 13.99
            #expect(report.entries.first?.budgeted == Decimal(400))
            #expect(report.entries.contains { $0.categoryName == "Transfer" } == false)
            #expect(report.total == Decimal(string: "66.39"))
        }
    }

    @Test("A private account's activity stays out of the partner's reports")
    func reportsRespectVisibility() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let bob = try await addBob(app, aliceToken: alice.token)

            // Alice privatizes the credit card (owns the Netflix 13.99).
            let card = try #require(try await accounts(app, token: alice.token).first { $0.type == .creditCard })
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { _ async in })

            let bobCF = try await julyCashFlow(app, token: bob.token)
            #expect(bobCF.expenses == Decimal(string: "52.40"))          // Whole Foods only
            let bobSpending = try await julySpending(app, token: bob.token)
            #expect(bobSpending.entries.contains { $0.categoryName == "Entertainment" } == false)

            let aliceCF = try await julyCashFlow(app, token: alice.token)
            #expect(aliceCF.expenses == Decimal(string: "66.39"))
        }
    }
}
