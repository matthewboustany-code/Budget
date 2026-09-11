import SwiftUI
import BudgetModels

/// Transactions grouped by day, with search, pagination, and navigation to the
/// detail (where recategorize / notes / comments / reactions live).
struct TransactionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var autoOpen: Transaction?
    @State private var showFilters = false

    private var store: TransactionStore { env.transactionStore }

    var body: some View {
        Group {
            if store.transactions.isEmpty && !store.isLoading {
                if store.filter.isActive {
                    ContentUnavailableView {
                        Label("No matches", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(store.filter == .needsReview ? "Everything has been reviewed." : "No transactions match these filters.")
                    } actions: {
                        Button("Clear filters") { store.filter = .init() }
                    }
                } else {
                    ContentUnavailableView("No transactions",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text("Connect a bank on the Accounts tab to see transactions."))
                }
            } else {
                List {
                    if store.filter.isActive {
                        Section {
                            HStack {
                                Label(filterSummary, systemImage: "line.3.horizontal.decrease.circle.fill")
                                    .font(.subheadline)
                                Spacer()
                                Button("Clear") { store.filter = .init() }
                                    .font(.subheadline)
                            }
                        }
                    }
                    ForEach(grouped, id: \.day) { section in
                        Section(section.day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(section.items) { tx in
                                NavigationLink(value: tx) { TransactionRow(transaction: tx) }
                                    .swipeActions(edge: .trailing) {
                                        if isManual(tx) {
                                            Button(role: .destructive) {
                                                Task { await store.delete(tx) }
                                            } label: { Label("Delete", systemImage: "trash") }
                                        }
                                    }
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
        .refreshable {
            // Ask the banks first, so pulling means "what's new", not just
            // "what the server already had".
            await env.accountStore.syncNow()
            await store.load(search: search)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showFilters = true } label: {
                    Image(systemName: store.filter.isActive
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filters")
            }
        }
        .sheet(isPresented: $showFilters) {
            TransactionFilterSheet(filter: store.filter) { store.filter = $0 }
        }
        // The dashboard's review row sets the filter from another tab.
        .onChange(of: store.filter) { Task { await store.load(search: search) } }
        .sheet(item: $autoOpen) { tx in NavigationStack { TransactionDetailView(transaction: tx) } }
        .task {
            if store.isStale() || store.loadedFilter != store.filter { await store.load(search: search) }
            #if DEBUG
            if LaunchArgs.has("-openFirstTransaction") { autoOpen = store.transactions.first }
            #endif
        }
    }

    /// Only manual-account transactions can be deleted; Plaid rows belong to the bank.
    private func isManual(_ tx: Transaction) -> Bool {
        env.accountStore.accounts.first { $0.id == tx.accountID }?.isManual == true
    }

    private var filterSummary: String {
        let f = store.filter
        var parts = [String]()
        if f.unreviewed { parts.append("Needs review") }
        if f.uncategorized { parts.append("Uncategorized") }
        else if let id = f.categoryID { parts.append(env.categoryStore.name(for: id)) }
        if let id = f.accountID, let account = env.accountStore.accounts.first(where: { $0.id == id }) {
            parts.append(account.name)
        }
        if f.from != nil || f.to != nil { parts.append("Date range") }
        return parts.joined(separator: " · ")
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
                if transaction.isSplit {
                    Label("Split · \(transaction.splits.count) categories", systemImage: "square.split.2x1")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(env.categoryStore.name(for: transaction.categoryID))
                        .font(.caption).foregroundStyle(.secondary)
                }
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

/// Edits a copy of the filter; nothing reloads until Apply.
struct TransactionFilterSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TransactionStore.Filter
    @State private var useDates: Bool
    let onApply: (TransactionStore.Filter) -> Void

    init(filter: TransactionStore.Filter, onApply: @escaping (TransactionStore.Filter) -> Void) {
        _draft = State(initialValue: filter)
        _useDates = State(initialValue: filter.from != nil || filter.to != nil)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Needs review", isOn: $draft.unreviewed)
                    Toggle("Uncategorized", isOn: $draft.uncategorized)
                }
                Section {
                    Picker("Account", selection: $draft.accountID) {
                        Text("Any").tag(UUID?.none)
                        ForEach(env.accountStore.accounts) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Category", selection: $draft.categoryID) {
                        Text("Any").tag(UUID?.none)
                        ForEach(env.categoryStore.categories.filter { !$0.isArchived }) {
                            Text($0.name).tag(UUID?.some($0.id))
                        }
                    }
                    .disabled(draft.uncategorized)
                }
                Section {
                    Toggle("Date range", isOn: $useDates)
                    if useDates {
                        DatePicker("From", selection: Binding(
                            get: { draft.from ?? Calendar.current.date(byAdding: .month, value: -1, to: .now)! },
                            set: { draft.from = $0 }), displayedComponents: .date)
                        DatePicker("To", selection: Binding(
                            get: { draft.to ?? .now }, set: { draft.to = $0 }), displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { draft = .init(); useDates = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(resolved); dismiss() }
                }
            }
        }
    }

    /// Whole days: from start-of-day to end-of-day (the server's `to` is
    /// inclusive), and the pickers' implicit defaults become real bounds.
    private var resolved: TransactionStore.Filter {
        var f = draft
        if f.uncategorized { f.categoryID = nil }
        if useDates {
            let cal = Calendar.current
            let from = f.from ?? cal.date(byAdding: .month, value: -1, to: .now)!
            let to = f.to ?? .now
            f.from = cal.startOfDay(for: from)
            f.to = cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: to))
        } else {
            f.from = nil; f.to = nil
        }
        return f
    }
}

/// Outflows show as −$X, inflows as +$X (matching the amount sign convention).
func signedCurrency(_ tx: Transaction, code: String? = nil) -> String {
    let magnitude = abs(tx.amount).formatted(.currency(code: code ?? "USD"))
    return tx.isInflow ? "+\(magnitude)" : "-\(magnitude)"
}
