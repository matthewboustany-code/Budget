import Testing
import Foundation
@testable import BudgetModels

@Suite("Month value type")
struct MonthTests {
    @Test func parsesAndFormats() {
        let m = Month("2026-07")
        #expect(m == Month(year: 2026, month: 7))
        #expect(m?.description == "2026-07")
    }

    @Test func rejectsMalformed() {
        #expect(Month("2026-13") == nil)
        #expect(Month("2026") == nil)
        #expect(Month("nope") == nil)
    }

    @Test func nextAndPreviousWrapYear() {
        #expect(Month(year: 2026, month: 12).next == Month(year: 2027, month: 1))
        #expect(Month(year: 2026, month: 1).previous == Month(year: 2025, month: 12))
    }

    @Test func comparableOrders() {
        #expect(Month(year: 2025, month: 12) < Month(year: 2026, month: 1))
        #expect(Month(year: 2026, month: 3) < Month(year: 2026, month: 4))
    }

    @Test func codableRoundTripsAsString() throws {
        let m = Month(year: 2026, month: 7)
        let data = try JSONEncoder().encode(m)
        #expect(String(data: data, encoding: .utf8) == "\"2026-07\"")
        #expect(try JSONDecoder().decode(Month.self, from: data) == m)
    }
}

@Suite("Model computed properties")
struct ModelComputedTests {
    @Test func liabilityAccountsSubtractFromNetWorth() {
        let card = Account(id: UUID(), householdID: UUID(), ownerMemberID: UUID(),
                           name: "Visa", type: .creditCard, currentBalance: 1200,
                           createdAt: Date())
        #expect(card.netWorthContribution == Money(-1200))

        let checking = Account(id: UUID(), householdID: UUID(), ownerMemberID: UUID(),
                               name: "Checking", type: .checking, currentBalance: 5000,
                               createdAt: Date())
        #expect(checking.netWorthContribution == Money(5000))
    }

    @Test func goalProgressClamps() {
        let g = Goal(id: UUID(), householdID: UUID(), name: "Trip",
                     targetAmount: 1000, currentAmount: 250, createdAt: Date())
        #expect(g.progress == 0.25)
        #expect(g.remaining == Money(750))
        #expect(g.isComplete == false)

        let done = Goal(id: UUID(), householdID: UUID(), name: "Done",
                        targetAmount: 1000, currentAmount: 1500, createdAt: Date())
        #expect(done.progress == 1.0)
        #expect(done.isComplete)
    }

    @Test func budgetProgressAvailableAndOverspend() {
        let p = BudgetProgress(categoryID: UUID(), month: Month(year: 2026, month: 7),
                               budgeted: 400, rolloverIn: 50, spent: 500)
        #expect(p.available == Money(-50))
        #expect(p.isOverspent)
    }
}
