import SwiftUI
import BudgetModels

/// Transactions grouped by day, with search, pagination, and navigation to the
/// detail (where recategorize / notes / comments / reactions live).
struct TransactionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var autoOpen: Transaction?

    private var store: TransactionStore { env.transactionStore }

    var body: some View {
        Group {
            if store.transactions.isEmpty && !store.isLoading {
                ContentUnavailableView("No transactions",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Connect a bank on the Accounts tab to see transactions."))
            } else {
                List {
                    ForEach(grouped, id: \.day) { section in
                        Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(section.items) { tx in
                                NavigationLink(value: tx) { TransactionRow(transaction: tx) }
                            }
                        }
                    }
                    if store.canLoadMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .onAppear { Task { await store.loadMore(search: search) } }
                    }
                }
            }
        }
        .navigationTitle("Transactions")
        .navigationDestination(for: Transaction.self) { TransactionDetailView(transaction: $0) }
        .searchable(text: $search, prompt: "Search merchants")
        .onSubmit(of: .search) { Task { await store.load(search: search) } }
        .onChange(of: search) { _, newValue in
            if newValue.isEmpty { Task { await store.load() } }
        }
        .refreshable { await store.load(search: search) }
        .sheet(item: $autoOpen) { tx in NavigationStack { TransactionDetailView(transaction: tx) } }
        .task {
            if store.transactions.isEmpty { await store.load() }
            #if DEBUG
            if LaunchArgs.has("-openFirstTransaction") { autoOpen = store.transactions.first }
            #endif
        }
    }

    private var grouped: [(day: Date, items: [Transaction])] {
        let calendar = Calendar.current
        let dict = Dictionary(grouping: store.transactions) { calendar.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { day in
            (day, (dict[day] ?? []).sorted { $0.date > $1.date })
        }
    }
}

struct TransactionRow: View {
    @Environment(AppEnvironment.self) private var env
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: env.categoryStore.icon(for: transaction.categoryID))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(transaction.merchantName ?? transaction.name)
                        .lineLimit(1)
                    if transaction.visibility == .private {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    if transaction.status == .pending {
                        Text("Pending").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(env.categoryStore.name(for: transaction.categoryID))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(signedCurrency(transaction))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(transaction.isInflow ? .green : .primary)
                if transaction.isReviewed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
        }
    }
}

/// Outflows show as −$X, inflows as +$X (matching the amount sign convention).
func signedCurrency(_ tx: Transaction, code: String? = nil) -> String {
    let magnitude = abs(tx.amount).formatted(.currency(code: code ?? "USD"))
    return tx.isInflow ? "+\(magnitude)" : "-\(magnitude)"
}
