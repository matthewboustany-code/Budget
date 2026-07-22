import SwiftUI
import Charts
import BudgetModels
import BudgetKit

/// Monarch-style home: net worth with its trend, this month's cash flow,
/// how the budgets are doing, and what's due soon — each card a glance,
/// with the full feature one tap away.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            netWorthSection
            if let error = env.reportsStore.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            cashFlowSection
            budgetSection
            billsSection
            Section {
                NavigationLink { GoalsView() } label: {
                    Label("Goals", systemImage: "target")
                }
                NavigationLink { ReportsView() } label: {
                    Label("Reports", systemImage: "chart.bar.xaxis")
                }
            }
        }
        .navigationTitle("Budget")
        .refreshable { await reload() }
        .task {
            if env.reportsStore.cashFlow.isEmpty { await reload() }
        }
    }

    private func reload() async {
        async let reports: Void = env.reportsStore.load()
        async let bills: Void = env.billsStore.load()
        async let accounts: Void = env.accountStore.load()
        async let budget: Void = env.budgetStore.load()
        _ = await (reports, bills, accounts, budget)
    }

    // MARK: - Net worth

    @ViewBuilder
    private var netWorthSection: some View {
        if let netWorth = env.accountStore.netWorth {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Net worth").font(.subheadline).foregroundStyle(.secondary)
                    Text(currency(netWorth.current.net))
                        .font(.system(.title, design: .rounded).bold())
                    if netWorth.series.count >= 2 {
                        NetWorthSparkline(points: netWorth.series + [netWorth.current])
                            .frame(height: 60)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Cash flow

    @ViewBuilder
    private var cashFlowSection: some View {
        if let month = env.reportsStore.currentMonth {
            Section("This month") {
                HStack {
                    cashStat("Income", month.income, .green)
                    Spacer()
                    cashStat("Spent", month.expenses, .primary)
                    Spacer()
                    cashStat(month.net < 0 ? "Overspent" : "Saved", abs(month.net),
                             month.net < 0 ? .red : .green)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func cashStat(_ label: String, _ amount: Money, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(currency(amount))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Budget summary

    @ViewBuilder
    private var budgetSection: some View {
        if let rollup = env.budgetStore.rollup {
            let budgeted = rollup.entries.filter { $0.budgeted + $0.rolloverIn > 0 }
            if !budgeted.isEmpty {
                let limit = budgeted.reduce(Money(0)) { $0 + $1.budgeted + $1.rolloverIn }
                let spent = budgeted.reduce(Money(0)) { $0 + $1.spent }
                Section("Budget") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(currency(spent)) of \(currency(limit))")
                                .font(.callout.monospacedDigit())
                            Spacer()
                            Text(limit - spent < 0
                                 ? "\(currency(abs(limit - spent))) over"
                                 : "\(currency(limit - spent)) left")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(limit - spent < 0 ? .red : .green)
                        }
                        ProgressView(value: fraction(spent, of: limit))
                            .tint(limit - spent < 0 ? .red : .green)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Upcoming bills

    @ViewBuilder
    private var billsSection: some View {
        let due = env.billsStore.bills.prefix(3)
        Section {
            ForEach(due) { bill in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bill.name)
                        Text(bill.dueDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(bill.status == .overdue ? .red : .secondary)
                    }
                    Spacer()
                    Text(currency(bill.amount))
                        .monospacedDigit()
                        .foregroundStyle(bill.status == .overdue ? .red : .primary)
                }
            }
            NavigationLink { BillsView() } label: {
                Label(due.isEmpty ? "Bills & Recurring" : "All bills",
                      systemImage: "calendar")
            }
        } header: {
            Text(due.isEmpty ? "Bills" : "Due soon")
        }
    }
}

/// Compact net-worth trend for the dashboard card — an area-backed line,
/// axes hidden (the headline number above carries the scale).
private struct NetWorthSparkline: View {
    let points: [NetWorthPoint]

    var body: some View {
        // Net worth can live far from zero (or below it). Pin the domain to
        // the data and anchor the area fill to the domain floor — the default
        // zero baseline would flatten the trend into a floor line.
        let values = points.map { double($0.net) }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.1, 1)
        Chart(points) { point in
            AreaMark(x: .value("Date", point.date),
                     yStart: .value("Floor", lo - pad),
                     yEnd: .value("Net", double(point.net)))
                .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Date", point.date), y: .value("Net", double(point.net)))
                .foregroundStyle(.tint)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .accessibilityLabel("Net worth trend")
    }
}

// MARK: - Shared formatting

private func currency(_ amount: Money) -> String {
    amount.formatted(.currency(code: "USD").precision(.fractionLength(amount == amount.rounded() ? 0 : 2)))
}

private func fraction(_ spent: Money, of limit: Money) -> Double {
    guard limit > 0 else { return spent > 0 ? 1 : 0 }
    return min(max(double(spent) / double(limit), 0), 1)
}

private func double(_ money: Money) -> Double {
    (money as NSDecimalNumber).doubleValue
}

private extension Money {
    func rounded() -> Money {
        var value = self
        var result = Money()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
