import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Budget routes + category CRUD (P4). Uses the mock Plaid transport, whose
/// fixture transactions land in July 2026: Whole Foods 52.40 (checking →
/// Groceries) and Netflix 13.99 (credit card → Entertainment).
@Suite("Budgets & category CRUD", .serialized)
struct BudgetTests {
    private let july = Month(year: 2026, month: 7)
    private let august = Month(year: 2026, month: 8)

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

    /// Alice signs in, creates a household (seeds categories), links sandbox data.
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

    private func categories(_ app: Application, token: String) async throws -> CategoriesResponse {
        var response: CategoriesResponse?
        try await app.testing().test(.GET, "v1/categories", headers: bearer(token),
            afterResponse: { res async throws in response = try res.content.decode(CategoriesResponse.self) })
        return try #require(response)
    }

    private func category(_ app: Application, token: String, named name: String) async throws -> BudgetCategory {
        try #require(try await categories(app, token: token).categories.first { $0.name == name })
    }

    private func setBudget(_ app: Application, token: String, categoryID: UUID,
                           month: Month, amount: Money, rollover: Bool = false) async throws {
        try await app.testing().test(.PUT, "v1/budgets/\(categoryID)", headers: bearer(token),
            beforeRequest: { try $0.content.encode(SetBudgetRequest(month: month, amount: amount, rolloverEnabled: rollover)) },
            afterResponse: { res async in #expect(res.status == .ok) })
    }

    private func monthBudgets(_ app: Application, token: String, month: Month) async throws -> BudgetMonthResponse {
        var response: BudgetMonthResponse?
        try await app.testing().test(.GET, "v1/budgets?month=\(month)", headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(BudgetMonthResponse.self)
            })
        return try #require(response)
    }

    @Test("Set a budget and read back the month rollup with actuals")
    func setAndReadBudget() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let groceries = try await category(app, token: alice.token, named: "Groceries")
            try await setBudget(app, token: alice.token, categoryID: groceries.id, month: july, amount: 400)

            let response = try await monthBudgets(app, token: alice.token, month: july)
            #expect(response.budgets.count == 1)
            #expect(response.budgets.first?.amount == Decimal(400))

            let progress = try #require(response.rollup.entries.first { $0.categoryID == groceries.id })
            #expect(progress.budgeted == Decimal(400))
            #expect(progress.spent == Decimal(string: "52.40"))
            #expect(progress.available == Decimal(string: "347.60"))

            // Netflix spending shows up even though Entertainment has no budget.
            let entertainment = try await category(app, token: alice.token, named: "Entertainment")
            let unbudgeted = try #require(response.rollup.entries.first { $0.categoryID == entertainment.id })
            #expect(unbudgeted.budgeted == 0)
            #expect(unbudgeted.spent == Decimal(string: "13.99"))
        }
    }

    @Test("Updating the same category+month overwrites, not duplicates")
    func upsertOverwrites() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let groceries = try await category(app, token: alice.token, named: "Groceries")
            try await setBudget(app, token: alice.token, categoryID: groceries.id, month: july, amount: 400)
            try await setBudget(app, token: alice.token, categoryID: groceries.id, month: july, amount: 550)

            let response = try await monthBudgets(app, token: alice.token, month: july)
            #expect(response.budgets.count == 1)
            #expect(response.budgets.first?.amount == Decimal(550))
        }
    }

    @Test("Rollover carries July's remainder into August")
    func rolloverAcrossMonths() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let groceries = try await category(app, token: alice.token, named: "Groceries")
            try await setBudget(app, token: alice.token, categoryID: groceries.id, month: july, amount: 400, rollover: true)
            try await setBudget(app, token: alice.token, categoryID: groceries.id, month: august, amount: 400, rollover: true)

            let response = try await monthBudgets(app, token: alice.token, month: august)
            let progress = try #require(response.rollup.entries.first { $0.categoryID == groceries.id })
            // July: 400 budgeted − 52.40 spent = 347.60 rolls into August.
            #expect(progress.rolloverIn == Decimal(string: "347.60"))
            #expect(progress.available == Decimal(string: "747.60"))
        }
    }

    @Test("A private account's spending is excluded from the partner's rollup")
    func rollupRespectsVisibility() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let bob = try await addBob(app, aliceToken: alice.token)

            // Alice privatizes the credit card (owns the Netflix transaction).
            var accounts: [Account] = []
            try await app.testing().test(.GET, "v1/accounts", headers: bearer(alice.token),
                afterResponse: { res async throws in accounts = try res.content.decode([Account].self) })
            let card = try #require(accounts.first { $0.type == .creditCard })
            try await app.testing().test(.PATCH, "v1/accounts/\(card.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { _ async in })

            let entertainment = try await category(app, token: alice.token, named: "Entertainment")
            let bobView = try await monthBudgets(app, token: bob.token, month: july)
            #expect(bobView.rollup.entries.first { $0.categoryID == entertainment.id } == nil)

            let aliceView = try await monthBudgets(app, token: alice.token, month: july)
            #expect(aliceView.rollup.entries.first { $0.categoryID == entertainment.id }?.spent == Decimal(string: "13.99"))
        }
    }

    @Test("Cannot budget another household's category, an income category, or a negative amount")
    func budgetValidation() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let groceries = try await category(app, token: alice.token, named: "Groceries")
            let paycheck = try await category(app, token: alice.token, named: "Paycheck")

            // Eve, in her own household, can't touch Alice's category.
            let eve = try await signIn(app, "dev:eve", "Eve")
            try await app.testing().test(.POST, "v1/household", headers: bearer(eve.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Elsewhere", memberDisplayName: "Eve")) },
                afterResponse: { _ async in })
            try await app.testing().test(.PUT, "v1/budgets/\(groceries.id)", headers: bearer(eve.token),
                beforeRequest: { try $0.content.encode(SetBudgetRequest(month: july, amount: 100)) },
                afterResponse: { res async in #expect(res.status == .notFound) })

            // Income categories can't be budgeted.
            try await app.testing().test(.PUT, "v1/budgets/\(paycheck.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(SetBudgetRequest(month: july, amount: 100)) },
                afterResponse: { res async in #expect(res.status == .badRequest) })

            // Negative amounts are rejected.
            try await app.testing().test(.PUT, "v1/budgets/\(groceries.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(SetBudgetRequest(month: july, amount: -5)) },
                afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test("Create, rename, and archive a custom category")
    func categoryCRUD() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let tree = try await categories(app, token: alice.token)
            let lifestyle = try #require(tree.groups.first { $0.name == "Lifestyle" })

            // Create "Pets" in Lifestyle.
            var pets: BudgetCategory?
            try await app.testing().test(.POST, "v1/categories", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateCategoryRequest(groupID: lifestyle.id, name: "Pets", icon: "pawprint")) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    pets = try res.content.decode(BudgetCategory.self)
                })
            let petsID = try #require(pets?.id)
            #expect(try await categories(app, token: alice.token).categories.contains { $0.id == petsID })

            // Rename it.
            try await app.testing().test(.PATCH, "v1/categories/\(petsID)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateCategoryRequest(name: "Pet Care")) },
                afterResponse: { res async throws in
                    #expect(try res.content.decode(BudgetCategory.self).name == "Pet Care")
                })

            // Archive it — gone from the tree.
            try await app.testing().test(.DELETE, "v1/categories/\(petsID)", headers: bearer(alice.token),
                afterResponse: { res async in #expect(res.status == .ok) })
            #expect(try await categories(app, token: alice.token).categories.contains { $0.id == petsID } == false)

            // A blank name is rejected.
            try await app.testing().test(.POST, "v1/categories", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateCategoryRequest(groupID: lifestyle.id, name: "   ")) },
                afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }
}
