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

@Suite("Budget predicate")
struct HasBudgetTests {
    @Test("Negative rollover past the budget still counts as budgeted")
    func negativeRolloverIsBudgeted() {
        let m = Month(year: 2026, month: 8)
        let overspent = BudgetProgress(categoryID: UUID(), month: m, budgeted: 100, rolloverIn: -150, spent: 20)
        let none = BudgetProgress(categoryID: UUID(), month: m, budgeted: 0, spent: 30)
        #expect(overspent.hasBudget)
        #expect(overspent.isOverspent)
        #expect(!none.hasBudget)
        let rollup = MonthBudget(month: m, entries: [overspent, none])
        #expect(rollup.budgetedEntries.map(\.categoryID) == [overspent.categoryID])
    }
}

@Suite("Widget snapshot")
struct WidgetSnapshotTests {
    private func snapshot(limit: Money, spent: Money) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(), budgetedLimit: limit, budgetedSpent: spent,
                       monthLabel: "September")
    }

    @Test("Nothing budgeted reads as no budget, not as $0 left")
    func unbudgetedIsNotZeroLeft() {
        let empty = snapshot(limit: 0, spent: 0)
        #expect(!empty.hasBudget)
        // The obvious spent/limit divides by zero here; the widget's ring must
        // still get a usable number.
        #expect(empty.spentFraction == 0)
        // Spending with no budget pins the ring full rather than dividing.
        #expect(snapshot(limit: 0, spent: 40).spentFraction == 1)
    }

    @Test("Overspending stays clamped and reports a negative remainder")
    func overspendClamps() {
        let over = snapshot(limit: 500, spent: 800)
        #expect(over.remaining == Money(-300))
        #expect(over.spentFraction == 1)     // never past the end of the ring
        let half = snapshot(limit: 400, spent: 100)
        #expect(half.spentFraction == 0.25)
        #expect(half.remaining == Money(300))
    }

    @Test("Round-trips through the shared coder the app and widget both use")
    func codableRoundTrip() throws {
        let due = Date(timeIntervalSince1970: 1_789_000_000)
        let original = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_788_000_000),
                                      budgetedLimit: Money(string: "2550.00")!,
                                      budgetedSpent: Money(string: "172.13")!,
                                      monthLabel: "September",
                                      nextBillName: "City Power",
                                      nextBillAmount: Money(string: "142.50")!,
                                      nextBillDueDate: due, nextBillIsOverdue: true)
        let data = try WidgetSharing.encoder().encode(original)
        let decoded = try WidgetSharing.decoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded == original)
        #expect(decoded.remaining == Money(string: "2377.87"))
    }
}
