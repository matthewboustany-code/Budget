import Testing
import Foundation
@testable import BudgetKit
import BudgetModels

/// Fixed UTC calendar so month bucketing is deterministic regardless of the
/// machine's time zone.
private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private let household = UUID()

private func tx(account: UUID, category: UUID?, amount: Money, on date: Date,
                merchant: String = "Store") -> Transaction {
    Transaction(id: UUID(), householdID: household, accountID: account,
                ownerMemberID: UUID(), amount: amount, date: date, name: merchant,
                merchantName: merchant, categoryID: category, createdAt: date)
}

@Suite("Budget calculations")
struct BudgetCalculationTests {
    let july = Month(year: 2026, month: 7)

    @Test func spentNetsRefundsWithinMonth() {
        let cat = UUID(), acct = UUID()
        let txs = [
            tx(account: acct, category: cat, amount: 100, on: date(2026, 7, 3)),
            tx(account: acct, category: cat, amount: 40, on: date(2026, 7, 10)),
            tx(account: acct, category: cat, amount: -25, on: date(2026, 7, 12)), // refund
            tx(account: acct, category: cat, amount: 999, on: date(2026, 8, 1)),  // other month
        ]
        let spent = BudgetCalculator.spent(in: cat, month: july, transactions: txs, calendar: utc)
        #expect(spent == Money(115))
    }

    @Test func progressWithoutRollover() {
        let cat = UUID(), acct = UUID()
        let budget = Budget(id: UUID(), householdID: household, categoryID: cat,
                            month: july, amount: 300)
        let txs = [tx(account: acct, category: cat, amount: 220, on: date(2026, 7, 5))]
        let p = BudgetCalculator.progress(categoryID: cat, month: july, transactions: txs,
                                          budgetsByCategoryMonth: [BudgetCalculator.key(cat, july): budget],
                                          calendar: utc)
        #expect(p.budgeted == Money(300))
        #expect(p.spent == Money(220))
        #expect(p.rolloverIn == Money(0))
        #expect(p.available == Money(80))
    }

    @Test func rolloverCarriesPriorRemainder() {
        let cat = UUID(), acct = UUID()
        let june = Month(year: 2026, month: 6)
        let juneBudget = Budget(id: UUID(), householdID: household, categoryID: cat,
                                month: june, amount: 200, rolloverEnabled: true)
        let julyBudget = Budget(id: UUID(), householdID: household, categoryID: cat,
                                month: july, amount: 200, rolloverEnabled: true)
        // Spent 150 in June -> 50 left rolls into July.
        let txs = [
            tx(account: acct, category: cat, amount: 150, on: date(2026, 6, 15)),
            tx(account: acct, category: cat, amount: 60, on: date(2026, 7, 4)),
        ]
        let budgets = [
            BudgetCalculator.key(cat, june): juneBudget,
            BudgetCalculator.key(cat, july): julyBudget,
        ]
        let p = BudgetCalculator.progress(categoryID: cat, month: july, transactions: txs,
                                          budgetsByCategoryMonth: budgets, calendar: utc)
        #expect(p.rolloverIn == Money(50))
        #expect(p.available == Money(200 + 50 - 60))
    }

    @Test func monthBudgetOmitsEmptyCategories() {
        let g = UUID()
        let used = BudgetCategory(id: UUID(), householdID: household, groupID: g, name: "Groceries")
        let unused = BudgetCategory(id: UUID(), householdID: household, groupID: g, name: "Pets")
        let budget = Budget(id: UUID(), householdID: household, categoryID: used.id,
                            month: july, amount: 500)
        let txs = [tx(account: UUID(), category: used.id, amount: 120, on: date(2026, 7, 8))]
        let mb = BudgetCalculator.monthBudget(month: july, categories: [used, unused],
                                              transactions: txs, budgets: [budget], calendar: utc)
        #expect(mb.entries.count == 1)
        #expect(mb.entries.first?.categoryID == used.id)
        #expect(mb.totalSpent == Money(120))
    }

    @Test func splitsBalanceValidation() {
        let parent = Transaction(
            id: UUID(), householdID: household, accountID: UUID(), ownerMemberID: UUID(),
            amount: 100, date: date(2026, 7, 1), name: "Costco",
            splits: [
                TransactionSplit(id: UUID(), categoryID: UUID(), amount: 70),
                TransactionSplit(id: UUID(), categoryID: UUID(), amount: 30),
            ], createdAt: date(2026, 7, 1))
        #expect(splitsBalance(parent))
    }
}

@Suite("Report calculations")
struct ReportCalculationTests {
    let july = Month(year: 2026, month: 7)

    @Test func cashFlowSeparatesInAndOut() {
        let acct = UUID()
        let txs = [
            tx(account: acct, category: nil, amount: -3000, on: date(2026, 7, 1)), // paycheck
            tx(account: acct, category: nil, amount: 500, on: date(2026, 7, 2)),
            tx(account: acct, category: nil, amount: 250, on: date(2026, 7, 20)),
        ]
        let cf = ReportCalculator.cashFlow(month: july, transactions: txs, calendar: utc)
        #expect(cf.income == Money(3000))
        #expect(cf.expenses == Money(750))
        #expect(cf.net == Money(2250))
    }

    @Test func spendingByCategorySortsDescending() {
        let g = UUID()
        let food = BudgetCategory(id: UUID(), householdID: household, groupID: g, name: "Food")
        let gas = BudgetCategory(id: UUID(), householdID: household, groupID: g, name: "Gas")
        let acct = UUID()
        let txs = [
            tx(account: acct, category: food.id, amount: 200, on: date(2026, 7, 3)),
            tx(account: acct, category: gas.id, amount: 80, on: date(2026, 7, 5)),
            tx(account: acct, category: food.id, amount: 50, on: date(2026, 7, 9)),
        ]
        let rows = ReportCalculator.spendingByCategory(month: july, categories: [food, gas],
                                                       transactions: txs, budgets: [], calendar: utc)
        #expect(rows.count == 2)
        #expect(rows.first?.categoryName == "Food")
        #expect(rows.first?.amount == Money(250))
    }

    @Test func netWorthNetsAssetsAndLiabilities() {
        let checking = Account(id: UUID(), householdID: household, ownerMemberID: UUID(),
                               name: "Checking", type: .checking, currentBalance: 8000,
                               createdAt: Date())
        let card = Account(id: UUID(), householdID: household, ownerMemberID: UUID(),
                           name: "Visa", type: .creditCard, currentBalance: 1500,
                           createdAt: Date())
        let hidden = Account(id: UUID(), householdID: household, ownerMemberID: UUID(),
                             name: "Old", type: .savings, currentBalance: 100000,
                             isHidden: true, createdAt: Date())
        let nw = ReportCalculator.netWorth(accounts: [checking, card, hidden])
        #expect(nw.assets == Money(8000))
        #expect(nw.liabilities == Money(1500))
        #expect(nw.net == Money(6500))
    }
}

@Suite("Recurring detection")
struct RecurringDetectorTests {
    @Test func detectsMonthlySubscription() {
        let acct = UUID()
        let txs = (0..<4).map { i in
            tx(account: acct, category: nil, amount: 15.99,
               on: date(2026, 4 + i, 14), merchant: "NETFLIX #\(i)")
        }
        let series = RecurringDetector.detect(transactions: txs, householdID: household,
                                              calendar: utc, now: date(2026, 7, 20))
        #expect(series.count == 1)
        #expect(series.first?.cadence == .monthly)
        #expect(series.first?.name.lowercased().contains("netflix") == true)
    }

    @Test func ignoresErraticMerchants() {
        let acct = UUID()
        let txs = [
            tx(account: acct, category: nil, amount: 12, on: date(2026, 5, 1), merchant: "Corner Store"),
            tx(account: acct, category: nil, amount: 200, on: date(2026, 5, 9), merchant: "Corner Store"),
            tx(account: acct, category: nil, amount: 4, on: date(2026, 6, 30), merchant: "Corner Store"),
        ]
        let series = RecurringDetector.detect(transactions: txs, householdID: household,
                                              calendar: utc, now: date(2026, 7, 1))
        #expect(series.isEmpty)
    }

    @Test func ignoresChargeRefundPairs() {
        let acct = UUID()
        // Same merchant, steady biweekly rhythm, but alternating +500/−500 —
        // a charge/refund pattern, not a subscription.
        let txs = (0..<4).map { i in
            tx(account: acct, category: nil, amount: i.isMultiple(of: 2) ? 500 : -500,
               on: date(2026, 5, 1 + 14 * i), merchant: "United Airlines")
        }
        let series = RecurringDetector.detect(transactions: txs, householdID: household,
                                              calendar: utc, now: date(2026, 7, 1))
        #expect(series.isEmpty)
    }
}

@Suite("Bill projection")
struct BillProjectorTests {
    private func series(name: String = "Netflix", amount: Money = Money(string: "15.99")!,
                        cadence: RecurringCadence = .monthly, next: Date?,
                        isActive: Bool = true) -> RecurringSeries {
        RecurringSeries(id: UUID(), householdID: household, name: name,
                        averageAmount: amount, cadence: cadence,
                        nextDate: next, isActive: isActive)
    }

    @Test func projectsMonthlyOccurrencesInWindow() {
        let netflix = series(next: date(2026, 7, 25))
        let bills = BillProjector.upcomingBills(series: [netflix],
                                                from: date(2026, 7, 22), to: date(2026, 9, 30),
                                                now: date(2026, 7, 22), calendar: utc)
        // July 25, Aug 25, Sep 25 — monthly stepping stays on the 25th.
        #expect(bills.count == 3)
        #expect(bills.map(\.dueDate) == [date(2026, 7, 25), date(2026, 8, 25), date(2026, 9, 25)])
        #expect(bills.allSatisfy { $0.status == .upcoming })
        #expect(bills.allSatisfy { $0.recurringSeriesID == netflix.id })
    }

    @Test func pastDueOccurrenceIsOverdue() {
        let rent = series(name: "Rent", amount: 2000, next: date(2026, 7, 18))
        let bills = BillProjector.upcomingBills(series: [rent],
                                                from: date(2026, 7, 15), to: date(2026, 7, 31),
                                                now: date(2026, 7, 22), calendar: utc)
        #expect(bills.count == 1)
        #expect(bills.first?.status == .overdue)
    }

    @Test func skipsInactiveIncomeAndIrregularSeries() {
        let all = [
            series(name: "Cancelled", next: date(2026, 7, 25), isActive: false),
            series(name: "Paycheck", amount: -3000, cadence: .biweekly, next: date(2026, 7, 24)),
            series(name: "Odd", cadence: .irregular, next: date(2026, 7, 24)),
            series(name: "No date", next: nil),
        ]
        let bills = BillProjector.upcomingBills(series: all,
                                                from: date(2026, 7, 22), to: date(2026, 8, 22),
                                                now: date(2026, 7, 22), calendar: utc)
        #expect(bills.isEmpty)
    }

    @Test func sortsAcrossSeriesByDueDate() {
        let bills = BillProjector.upcomingBills(
            series: [series(name: "Late", next: date(2026, 8, 9)),
                     series(name: "Soon", cadence: .weekly, next: date(2026, 7, 23))],
            from: date(2026, 7, 22), to: date(2026, 8, 10),
            now: date(2026, 7, 22), calendar: utc)
        #expect(bills.map(\.name) == ["Soon", "Soon", "Soon", "Late"])
    }
}
