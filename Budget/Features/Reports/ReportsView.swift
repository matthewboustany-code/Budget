import SwiftUI
import Charts
import BudgetModels
import BudgetKit

/// Reports: income-vs-spending trend, where the money went (per category,
/// with budgets), and net worth over time. All server-computed from the
/// caller's visible transactions; transfers are excluded throughout.
struct ReportsView: View {
    @Environment(AppEnvironment.self) private var env

    private var store: ReportsStore { env.reportsStore }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            cashFlowSection
            spendingSection
            netWorthSection
        }
        .navigationTitle("Reports")
        .refreshable { await store.load() }
        .task {
            if store.cashFlow.isEmpty { await store.load() }
            if env.accountStore.netWorth == nil { await env.accountStore.load() }
        }
    }

    // MARK: - Cash flow trend

    @ViewBuilder
    private var cashFlowSection: some View {
        if !store.cashFlow.isEmpty {
            Section("Cash flow — last 6 months") {
                Chart {
                    ForEach(store.cashFlow, id: \.month) { summary in
                        BarMark(x: .value("Month", label(summary.month)),
                                y: .value("Amount", double(summary.income)),
                                width: .ratio(0.35))
                            .position(by: .value("Kind", "Income"))
                            .foregroundStyle(by: .value("Kind", "Income"))
                        BarMark(x: .value("Month", label(summary.month)),
                                y: .value("Amount", double(summary.expenses)),
                                width: .ratio(0.35))
                            .position(by: .value("Kind", "Spending"))
                            .foregroundStyle(by: .value("Kind", "Spending"))
                    }
                }
                .chartForegroundStyleScale(["Income": Color.green, "Spending": Color.red.opacity(0.75)])
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 220)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Spending by category

    @ViewBuilder
    private var spendingSection: some View {
        Section {
            HStack {
                Button {
                    Task { await store.showPreviousSpendingMonth() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(store.spendingMonth.startDate().formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    Task { await store.showNextSpendingMonth() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.borderless)

            if let spending = store.spending, !spending.entries.isEmpty {
                Chart(spending.entries.prefix(8)) { entry in
                    BarMark(x: .value("Amount", double(entry.amount)),
                            y: .value("Category", entry.categoryName))
                        .foregroundStyle(.tint)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(currency(entry.amount))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(preset: .extended) { _ in AxisValueLabel() }
                }
                .frame(height: CGFloat(min(store.spending?.entries.count ?? 0, 8)) * 36 + 16)
                .padding(.vertical, 4)

                LabeledContent("Total spent") {
                    Text(currency(spending.total)).monospacedDigit().fontWeight(.semibold)
                }
            } else {
                Text("No spending recorded this month.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        } header: {
            Text("Where it went")
        } footer: {
            Text("Transfers between your own accounts are left out.")
        }
    }

    // MARK: - Net worth over time

    @ViewBuilder
    private var netWorthSection: some View {
        if let netWorth = env.accountStore.netWorth {
            let points = netWorth.series + [netWorth.current]
            if points.count >= 2 {
                // Same domain treatment as the dashboard sparkline: scale to
                // the data and anchor the fill to the floor, not to zero.
                let values = points.map { double($0.net) }
                let lo = values.min() ?? 0
                let hi = values.max() ?? 1
                let pad = max((hi - lo) * 0.1, 1)
                Section("Net worth") {
                    Chart(points) { point in
                        AreaMark(x: .value("Date", point.date),
                                 yStart: .value("Floor", lo - pad),
                                 yEnd: .value("Net", double(point.net)))
                            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear],
                                                             startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", point.date), y: .value("Net", double(point.net)))
                            .foregroundStyle(.tint)
                    }
                    .chartYScale(domain: (lo - pad)...(hi + pad))
                    .frame(height: 180)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func label(_ month: Month) -> String {
        month.startDate().formatted(.dateTime.month(.abbreviated))
    }
}

private func currency(_ amount: Money) -> String {
    amount.formatted(.currency(code: "USD").precision(.fractionLength(0)))
}

private func double(_ money: Money) -> Double {
    (money as NSDecimalNumber).doubleValue
}
