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

    @Test func averageAmountIsRoundedToCents() {
        let acct = UUID()
        // 175 + 176.45 + 178 = 529.45 → 176.48333…, the T-Mobile case.
        let txs = zip([Money(175), Money(string: "176.45")!, Money(178)], 0...).map { amount, i in
            tx(account: acct, category: nil, amount: amount,
               on: date(2026, 5 + i, 10), merchant: "T-Mobile")
        }
        let series = RecurringDetector.detect(transactions: txs, householdID: household,
                                              calendar: utc, now: date(2026, 7, 20))
        #expect(series.first?.averageAmount == Money(string: "176.48"))
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
                        nextDate: next, isActive: isActive,
                        merchantKey: RecurringDetector.normalize(name))
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

    // MARK: - Paid matching (4.5)

    @Test("A charge inside the tolerance marks the occurrence paid")
    func matchingChargeMarksPaid() {
        let netflix = series(next: date(2026, 7, 25))
        // Posted two days late — inside the -3…+5 window.
        let charge = tx(account: UUID(), category: nil, amount: Money(string: "15.99")!,
                        on: date(2026, 7, 27), merchant: "NETFLIX.COM")
        let bills = BillProjector.upcomingBills(series: [netflix],
                                                from: date(2026, 7, 20), to: date(2026, 8, 30),
                                                recentTransactions: [charge],
                                                now: date(2026, 7, 28), calendar: utc)
        #expect(bills.map(\.dueDate) == [date(2026, 7, 25), date(2026, 8, 25)])
        #expect(bills.first?.status == .paid)
        // The next month is untouched by July's payment.
        #expect(bills.last?.status == .upcoming)
    }

    @Test("A charge outside the tolerance, or from another merchant, does not")
    func nonMatchingChargesLeaveTheBillDue() {
        let netflix = series(next: date(2026, 7, 25))
        let tooLate = tx(account: UUID(), category: nil, amount: 15, on: date(2026, 8, 1),
                         merchant: "Netflix")
        let other = tx(account: UUID(), category: nil, amount: 15, on: date(2026, 7, 25),
                       merchant: "Hulu")
        let refund = tx(account: UUID(), category: nil, amount: -15, on: date(2026, 7, 25),
                        merchant: "Netflix")
        let bills = BillProjector.upcomingBills(series: [netflix],
                                                from: date(2026, 7, 20), to: date(2026, 7, 31),
                                                recentTransactions: [tooLate, other, refund],
                                                now: date(2026, 7, 26), calendar: utc)
        #expect(bills.count == 1)
        #expect(bills.first?.status == .overdue)
    }

    @Test("One charge cannot pay two occurrences of the same series")
    func eachChargeIsClaimedOnce() {
        // Weekly, so two due dates sit inside one charge's tolerance.
        let gym = series(name: "Gym", amount: 20, cadence: .weekly, next: date(2026, 7, 20))
        let charge = tx(account: UUID(), category: nil, amount: 20, on: date(2026, 7, 24),
                        merchant: "Gym")
        let bills = BillProjector.upcomingBills(series: [gym],
                                                from: date(2026, 7, 20), to: date(2026, 7, 28),
                                                recentTransactions: [charge],
                                                now: date(2026, 7, 25), calendar: utc)
        #expect(bills.map(\.dueDate) == [date(2026, 7, 20), date(2026, 7, 27)])
        #expect(bills.map(\.status) == [.paid, .upcoming])
    }

    @Test("An occurrence detection has already stepped past still shows as paid")
    func backWalkSurfacesTheJustPaidOccurrence() {
        // Netflix posted on the 25th; detection advanced nextDate to Aug 25,
        // so without the back-walk July's occurrence would vanish entirely.
        let netflix = series(next: date(2026, 8, 25))
        let charge = tx(account: UUID(), category: nil, amount: Money(string: "15.99")!,
                        on: date(2026, 7, 25), merchant: "Netflix")
        let bills = BillProjector.upcomingBills(series: [netflix],
                                                from: date(2026, 7, 14), to: date(2026, 8, 28),
                                                recentTransactions: [charge],
                                                now: date(2026, 7, 28), calendar: utc)
        #expect(bills.map(\.dueDate) == [date(2026, 7, 25), date(2026, 8, 25)])
        #expect(bills.map(\.status) == [.paid, .upcoming])
    }

    @Test("An unmatched past occurrence is history, not a new overdue bill")
    func backWalkInventsNothing() {
        let netflix = series(next: date(2026, 8, 25))
        let bills = BillProjector.upcomingBills(series: [netflix],
                                                from: date(2026, 7, 14), to: date(2026, 8, 28),
                                                recentTransactions: [],
                                                now: date(2026, 7, 28), calendar: utc)
        #expect(bills.map(\.dueDate) == [date(2026, 8, 25)])
    }

    @Test("A series with no merchant key is never auto-paid")
    func handMadeSeriesStayDue() {
        var manual = series(name: "Loan to Sam", amount: 50, next: date(2026, 7, 25))
        manual.merchantKey = nil
        let charge = tx(account: UUID(), category: nil, amount: 50, on: date(2026, 7, 25),
                        merchant: "Loan to Sam")
        let bills = BillProjector.upcomingBills(series: [manual],
                                                from: date(2026, 7, 20), to: date(2026, 7, 31),
                                                recentTransactions: [charge],
                                                now: date(2026, 7, 20), calendar: utc)
        #expect(bills.first?.status == .upcoming)
    }
}

@Suite("Calendar-day dates")
struct CalendarDayTests {
    /// Plaid's day-only dates are stored at 12:00 UTC so they fall on the same
    /// calendar day in any zone within ±12 h. At midnight UTC this charge
    /// would land in July for a Los Angeles user.
    @Test("A noon-UTC date on the 1st stays in its month in LA and UTC")
    func noonDateBucketsSameMonthInUSAndUTC() {
        var noonUTC = utc
        noonUTC.timeZone = TimeZone(identifier: "UTC")!
        let firstOfAugust = noonUTC.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12))!
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(Month(date: firstOfAugust, calendar: la) == Month(year: 2026, month: 8))
        #expect(Month(date: firstOfAugust, calendar: utc) == Month(year: 2026, month: 8))
        #expect(la.component(.day, from: firstOfAugust) == 1)
    }
}

@Suite("Recurring next date")
struct RecurringNextDateTests {
    @Test("A monthly bill on the 31st predicts the end of February, not March 2")
    func monthlyNextDateClampsToMonthEnd() throws {
        let account = UUID()
        let charges = [date(2025, 11, 30), date(2025, 12, 31), date(2026, 1, 31)].map {
            tx(account: account, category: nil, amount: 15, on: $0, merchant: "Gym")
        }
        let series = try #require(RecurringDetector.detect(
            transactions: charges, householdID: household, calendar: utc, now: date(2026, 2, 1)).first)
        #expect(series.cadence == .monthly)
        #expect(series.nextDate == date(2026, 2, 28))
    }
}

/// The original rollup: `progress` per category, which rescans every
/// transaction per rollover level. Kept here only to pin the bucketed
/// `monthBudget` to identical output.
private func _referenceMonthBudget(month: Month, categories: [BudgetCategory],
                                   transactions: [Transaction], budgets: [Budget],
                                   calendar: Calendar) -> MonthBudget {
    let byKey = Dictionary(budgets.map { (BudgetCalculator.key($0.categoryID, $0.month), $0) },
                           uniquingKeysWith: { a, _ in a })
    let entries = categories.compactMap { category -> BudgetProgress? in
        let p = BudgetCalculator.progress(categoryID: category.id, month: month, transactions: transactions,
                                          budgetsByCategoryMonth: byKey, calendar: calendar)
        return (p.budgeted == 0 && p.spent == 0 && p.rolloverIn == 0) ? nil : p
    }
    return MonthBudget(month: month, entries: entries)
}

@Suite("Bucketed budget rollup")
struct BucketedRollupTests {
    @Test("Matches the reference algorithm on a randomized fixture", arguments: [1, 2, 3, 42, 2026])
    func matchesReference(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let group = UUID()
        let categories = (0..<8).map {
            BudgetCategory(id: UUID(), householdID: household, groupID: group, name: "C\($0)")
        }
        let start = Month(year: 2024, month: 1)
        var months: [Month] = [start]
        for _ in 1..<30 { months.append(months.last!.next) }

        var budgets: [Budget] = []
        for c in categories where rng.next() % 4 != 0 {
            // Rollover chains with gaps: some months unbudgeted, some with rollover off.
            for m in months where rng.next() % 5 != 0 {
                budgets.append(Budget(id: UUID(), householdID: household, categoryID: c.id, month: m,
                                      amount: Money(Int(rng.next() % 400)),
                                      rolloverEnabled: rng.next() % 3 != 0))
            }
        }
        let account = UUID()
        var txs: [Transaction] = []
        for i in 0..<1500 {
            let m = months[Int(rng.next() % UInt64(months.count))]
            let day = Int(rng.next() % 28) + 1
            let on = utc.date(from: DateComponents(year: m.year, month: m.month, day: day, hour: 12))!
            let amount = Money(Int(rng.next() % 300)) - (rng.next() % 10 == 0 ? 400 : 0)  // some refunds
            let pick = { categories[Int(rng.next() % UInt64(categories.count))].id }
            if rng.next() % 8 == 0 {
                let first = Money(Int(rng.next() % 100))
                txs.append(Transaction(id: UUID(), householdID: household, accountID: account,
                                       ownerMemberID: UUID(), amount: amount, date: on, name: "Split \(i)",
                                       splits: [TransactionSplit(id: UUID(), categoryID: pick(), amount: first),
                                                TransactionSplit(id: UUID(), categoryID: pick(), amount: amount - first)],
                                       createdAt: on))
            } else {
                let category: UUID? = rng.next() % 12 == 0 ? nil : pick()
                txs.append(tx(account: account, category: category, amount: amount, on: on))
            }
        }
        for month in [months[0], months[12], months[29], months[29].next] {
            let fast = BudgetCalculator.monthBudget(month: month, categories: categories,
                                                    transactions: txs, budgets: budgets, calendar: utc)
            let reference = _referenceMonthBudget(month: month, categories: categories,
                                                  transactions: txs, budgets: budgets, calendar: utc)
            #expect(fast == reference)
        }
    }
}

/// Deterministic PRNG so a failing seed reproduces.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
