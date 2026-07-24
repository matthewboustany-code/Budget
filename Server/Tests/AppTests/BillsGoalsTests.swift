import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Recurring detection, the upcoming-bills projection, and goals (P5).
/// Recurring history is seeded straight through the DB pool (the Plaid mock's
/// fixtures only have single occurrences), relative to the real clock because
/// detection's is-this-still-active check compares against `Date()`.
@Suite("Bills, recurring & goals", .serialized)
struct BillsGoalsTests {

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

    /// Alice signs in, creates a household, links the sandbox accounts.
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

    private func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())!
    }

    /// Seed a merchant's history straight into the DB: one transaction every
    /// 30 days, the most recent `lastDaysAgo` days ago.
    private func seedMonthly(_ app: Application, account: Account, merchant: String,
                             amount: Money, occurrences: Int = 4, lastDaysAgo: Int = 5,
                             visibility: Visibility = .shared) async throws {
        try await app.appDatabase.dbPool.write { db in
            for i in 0..<occurrences {
                let tx = BudgetModels.Transaction(
                    id: UUID(), householdID: account.householdID, accountID: account.id,
                    ownerMemberID: account.ownerMemberID, amount: amount,
                    date: Calendar.current.date(byAdding: .day, value: -(lastDaysAgo + 30 * i), to: Date())!,
                    name: merchant, merchantName: merchant, visibility: visibility,
                    plaidTransactionID: "seed-\(merchant)-\(i)", createdAt: Date())
                try TransactionStore.upsertPlaid(tx, db)
            }
        }
    }

    private func refresh(_ app: Application, token: String) async throws -> [RecurringSeries] {
        var out: [RecurringSeries] = []
        try await app.testing().test(.POST, "v1/recurring/refresh", headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                out = try res.content.decode([RecurringSeries].self)
            })
        return out
    }

    private func recurring(_ app: Application, token: String) async throws -> [RecurringSeries] {
        var out: [RecurringSeries] = []
        try await app.testing().test(.GET, "v1/recurring", headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                out = try res.content.decode([RecurringSeries].self)
            })
        return out
    }

    private func upcomingBills(_ app: Application, token: String) async throws -> [Bill] {
        var out: [Bill] = []
        try await app.testing().test(.GET, "v1/bills/upcoming", headers: bearer(token),
            afterResponse: { res async throws in
                #expect(res.status == .ok)
                out = try res.content.decode(UpcomingBillsResponse.self).bills
            })
        return out
    }

    // MARK: - Recurring & bills

    @Test("Detection finds a monthly subscription and projects its next bill")
    func detectionAndProjection() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            try await seedMonthly(app, account: checking, merchant: "Spotify",
                                  amount: Decimal(string: "9.99")!)

            let series = try await refresh(app, token: alice.token)
            let spotify = try #require(series.first { $0.name.lowercased().contains("spotify") })
            #expect(spotify.cadence == .monthly)
            #expect(spotify.averageAmount == Decimal(string: "9.99"))
            #expect(spotify.isActive)
            #expect(spotify.accountID == checking.id)

            // Last charge was 5 days ago → next due in ~25 days, inside the
            // default 30-day window.
            let bills = try await upcomingBills(app, token: alice.token)
            let bill = try #require(bills.first { $0.recurringSeriesID == spotify.id })
            #expect(bill.status == .upcoming)
            #expect(bill.amount == Decimal(string: "9.99"))
            #expect(bill.dueDate > Date())
        }
    }

    @Test("An expected-but-unposted bill shows as overdue")
    func overdueBill() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            // Last charge 32 days ago → next expected ~2 days ago.
            try await seedMonthly(app, account: checking, merchant: "Gym Membership",
                                  amount: 40, lastDaysAgo: 32)

            _ = try await refresh(app, token: alice.token)
            let bills = try await upcomingBills(app, token: alice.token)
            let gym = try #require(bills.first { $0.name.lowercased().contains("gym") })
            #expect(gym.status == .overdue)
        }
    }

    @Test("Turning a series off sticks across re-detection and hides its bills")
    func toggleOffIsSticky() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            try await seedMonthly(app, account: checking, merchant: "Spotify",
                                  amount: Decimal(string: "9.99")!)
            let series = try await refresh(app, token: alice.token)
            let spotify = try #require(series.first { $0.name.lowercased().contains("spotify") })

            try await app.testing().test(.PATCH, "v1/recurring/\(spotify.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateRecurringRequest(isActive: false)) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(RecurringSeries.self).isActive == false)
                })

            #expect(try await upcomingBills(app, token: alice.token)
                .contains { $0.recurringSeriesID == spotify.id } == false)

            // Re-running detection neither duplicates the series nor re-enables it.
            let after = try await refresh(app, token: alice.token)
            let matches = after.filter { $0.name.lowercased().contains("spotify") }
            #expect(matches.count == 1)
            #expect(matches.first?.isActive == false)
            #expect(matches.first?.id == spotify.id)
        }
    }

    @Test("Renaming a series survives re-detection without spawning a duplicate")
    func renameDoesNotDuplicate() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            try await seedMonthly(app, account: checking, merchant: "Spotify",
                                  amount: Decimal(string: "9.99")!)
            let series = try await refresh(app, token: alice.token)
            let spotify = try #require(series.first { $0.name.lowercased().contains("spotify") })

            // The user owns the name — rename the detected series.
            try await app.testing().test(.PATCH, "v1/recurring/\(spotify.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateRecurringRequest(name: "Music Subscription")) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try res.content.decode(RecurringSeries.self).name == "Music Subscription")
                })

            // Re-detection matches on the immutable merchant key, so it updates
            // the same row instead of re-inserting under the merchant name.
            let after = try await refresh(app, token: alice.token)
            #expect(after.filter { $0.id == spotify.id }.count == 1)
            let renamed = try #require(after.first { $0.id == spotify.id })
            #expect(renamed.name == "Music Subscription")            // rename preserved
            #expect(renamed.averageAmount == Decimal(string: "9.99")) // numbers still updated
            #expect(after.contains { $0.name.lowercased().contains("spotify") } == false)
        }
    }

    @Test("A series from a private account is invisible to the partner")
    func privateAccountSeriesHidden() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let bob = try await addBob(app, aliceToken: alice.token)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            try await app.testing().test(.PATCH, "v1/accounts/\(checking.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateAccountRequest(visibility: .private)) },
                afterResponse: { _ async in })

            try await seedMonthly(app, account: checking, merchant: "Spotify",
                                  amount: Decimal(string: "9.99")!)
            let aliceSeries = try await refresh(app, token: alice.token)
            let spotify = try #require(aliceSeries.first { $0.name.lowercased().contains("spotify") })

            // Bob sees neither the series, its bills, nor the PATCH surface.
            #expect(try await recurring(app, token: bob.token)
                .contains { $0.id == spotify.id } == false)
            #expect(try await upcomingBills(app, token: bob.token)
                .contains { $0.recurringSeriesID == spotify.id } == false)
            try await app.testing().test(.PATCH, "v1/recurring/\(spotify.id)", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(UpdateRecurringRequest(isActive: false)) },
                afterResponse: { res async in #expect(res.status == .notFound) })
        }
    }

    @Test("Transactions the owner marked private never feed detection")
    func privateTransactionsExcludedFromDetection() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let checking = try #require(try await accounts(app, token: alice.token).first { $0.type == .checking })
            try await seedMonthly(app, account: checking, merchant: "Secret Box",
                                  amount: 25, visibility: .private)

            // Even the owner gets no series — private history stays out of the
            // household-wide detector entirely.
            let series = try await refresh(app, token: alice.token)
            #expect(series.contains { $0.name.lowercased().contains("secret") } == false)
        }
    }

    // MARK: - Goals

    @Test("Create, fund, edit, and delete a goal; totals track contributions")
    func goalLifecycle() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)
            let bob = try await addBob(app, aliceToken: alice.token)

            var goal: Goal?
            try await app.testing().test(.POST, "v1/goals", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateGoalRequest(name: "Vacation", targetAmount: 3000,
                                                                         icon: "airplane")) },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    goal = try res.content.decode(Goal.self)
                })
            let vacation = try #require(goal)
            #expect(vacation.currentAmount == 0)

            // Both partners fund the shared goal.
            try await app.testing().test(.POST, "v1/goals/\(vacation.id)/contributions", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(AddContributionRequest(amount: 500, note: "tax refund")) },
                afterResponse: { res async throws in
                    #expect(try res.content.decode(GoalDetailResponse.self).goal.currentAmount == 500)
                })
            var detail: GoalDetailResponse?
            try await app.testing().test(.POST, "v1/goals/\(vacation.id)/contributions", headers: bearer(bob.token),
                beforeRequest: { try $0.content.encode(AddContributionRequest(amount: 250)) },
                afterResponse: { res async throws in detail = try res.content.decode(GoalDetailResponse.self) })
            let funded = try #require(detail)
            #expect(funded.goal.currentAmount == 750)
            #expect(funded.contributions.count == 2)
            #expect(Set(funded.contributions.compactMap(\.memberID)).count == 2)

            // Withdrawals are negative contributions.
            try await app.testing().test(.POST, "v1/goals/\(vacation.id)/contributions", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(AddContributionRequest(amount: -100)) },
                afterResponse: { res async throws in
                    #expect(try res.content.decode(GoalDetailResponse.self).goal.currentAmount == 650)
                })

            // Rename + retarget.
            try await app.testing().test(.PATCH, "v1/goals/\(vacation.id)", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(UpdateGoalRequest(name: "Hawaii", targetAmount: 4000)) },
                afterResponse: { res async throws in
                    let updated = try res.content.decode(Goal.self)
                    #expect(updated.name == "Hawaii")
                    #expect(updated.targetAmount == 4000)
                    #expect(updated.currentAmount == 650)   // untouched by PATCH
                })

            // Delete → gone from the list.
            try await app.testing().test(.DELETE, "v1/goals/\(vacation.id)", headers: bearer(alice.token),
                afterResponse: { res async in #expect(res.status == .ok) })
            try await app.testing().test(.GET, "v1/goals", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(try res.content.decode([Goal].self).isEmpty)
                })
        }
    }

    @Test("Goal validation and cross-household isolation")
    func goalValidationAndIsolation() async throws {
        try await withApp { app in
            let alice = try await setupAlice(app)

            // Blank name / non-positive target / zero contribution are rejected.
            try await app.testing().test(.POST, "v1/goals", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateGoalRequest(name: "   ", targetAmount: 100)) },
                afterResponse: { res async in #expect(res.status == .badRequest) })
            try await app.testing().test(.POST, "v1/goals", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateGoalRequest(name: "Car", targetAmount: 0)) },
                afterResponse: { res async in #expect(res.status == .badRequest) })

            var goal: Goal?
            try await app.testing().test(.POST, "v1/goals", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateGoalRequest(name: "Car", targetAmount: 8000)) },
                afterResponse: { res async throws in goal = try res.content.decode(Goal.self) })
            let car = try #require(goal)
            try await app.testing().test(.POST, "v1/goals/\(car.id)/contributions", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(AddContributionRequest(amount: 0)) },
                afterResponse: { res async in #expect(res.status == .badRequest) })

            // Eve, in her own household, can't see or touch Alice's goal.
            let eve = try await signIn(app, "dev:eve", "Eve")
            try await app.testing().test(.POST, "v1/household", headers: bearer(eve.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "Elsewhere", memberDisplayName: "Eve")) },
                afterResponse: { _ async in })
            try await app.testing().test(.GET, "v1/goals/\(car.id)", headers: bearer(eve.token),
                afterResponse: { res async in #expect(res.status == .notFound) })
            try await app.testing().test(.PATCH, "v1/goals/\(car.id)", headers: bearer(eve.token),
                beforeRequest: { try $0.content.encode(UpdateGoalRequest(name: "Mine now")) },
                afterResponse: { res async in #expect(res.status == .notFound) })
            try await app.testing().test(.DELETE, "v1/goals/\(car.id)", headers: bearer(eve.token),
                afterResponse: { res async in #expect(res.status == .notFound) })
            try await app.testing().test(.POST, "v1/goals/\(car.id)/contributions", headers: bearer(eve.token),
                beforeRequest: { try $0.content.encode(AddContributionRequest(amount: 50)) },
                afterResponse: { res async in #expect(res.status == .notFound) })
        }
    }
}
