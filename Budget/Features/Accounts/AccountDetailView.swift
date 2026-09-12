import SwiftUI
import Charts
import BudgetModels

/// One account: current balance, the balance history from the nightly
/// snapshots, and its most recent transactions with a way into the full,
/// pre-filtered list.
struct AccountDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let account: Account

    @State private var points: [AccountBalancePoint] = []
    @State private var recent: [Transaction] = []
    @State private var isLoading = true

    /// The account as the store currently knows it — a balance edit elsewhere
    /// should be reflected here rather than showing the value we were pushed
    /// with.
    private var current: Account {
        env.accountStore.accounts.first { $0.id == account.id } ?? account
    }

    var body: some View {
        List {
            balanceSection
            historySection
            transactionsSection
        }
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let result = await env.accountStore.history(for: account.id) else { return }
        points = result.history.points
        recent = result.recent
    }

    // MARK: - Balance

    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(currency(current.currentBalance, code: current.currencyCode))
                    .font(.largeTitle.bold().monospacedDigit())
                    .foregroundStyle(current.type.isLiability ? .red : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var subtitle: String {
        var parts: [String] = [current.type.groupTitle]
        if let institution = current.institutionName {
            parts.append(current.mask.map { "\(institution) ••\($0)" } ?? institution)
        } else if current.isManual {
            parts.append("Manual")
        }
        if let available = current.availableBalance, available != current.currentBalance {
            parts.append("\(currency(available, code: current.currencyCode)) available")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section("Balance history") {
            if points.count >= 2 {
                // Scale to the data and anchor the fill to the floor: a credit
                // card's balances are all negative, and a zero baseline would
                // flatten the whole series against the top of the chart.
                let values = points.map { double($0.current) }
                let lo = values.min() ?? 0
                let hi = values.max() ?? 1
                let pad = max((hi - lo) * 0.1, 1)
                Chart(points) { point in
                    AreaMark(x: .value("Date", point.date),
                             yStart: .value("Floor", lo - pad),
                             yEnd: .value("Balance", double(point.current)))
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date),
                             y: .value("Balance", double(point.current)))
                        .foregroundStyle(.tint)
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .frame(height: 180)
                .padding(.vertical, 4)
            } else {
                Text(isLoading ? "Loading…" : "Balance history starts once this account has been synced on two different days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transactions

    @ViewBuilder
    private var transactionsSection: some View {
        Section("Recent transactions") {
            if recent.isEmpty {
                Text(isLoading ? "Loading…" : "No transactions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recent) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                }
                Button("See all in Transactions") {
                    var filter = TransactionStore.Filter()
                    filter.accountID = account.id
                    env.transactionStore.filter = filter
                    env.selectedTab = .transactions
                }
            }
        }
    }

    private func double(_ money: Money) -> Double {
        NSDecimalNumber(decimal: money).doubleValue
    }
}
