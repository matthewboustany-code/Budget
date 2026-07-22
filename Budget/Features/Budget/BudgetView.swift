import SwiftUI
import BudgetModels
import BudgetKit

/// Monarch-style monthly budgets: step between months, see budget-vs-actual
/// per category with progress bars, and tap any category to set its limit
/// and rollover. Income groups are excluded — they belong to cash flow.
struct BudgetView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: BudgetCategory?

    private var store: BudgetStore { env.budgetStore }

    var body: some View {
        List {
            monthSection
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            if let rollup = store.rollup, !rollup.entries.isEmpty {
                summarySection(rollup)
            }
            categorySections
        }
        .navigationTitle("Budget")
        .sheet(item: $editing) { category in
            SetBudgetSheet(category: category)
                .presentationDetents([.medium])
        }
        .refreshable { await store.load() }
        .task {
            if store.rollup == nil { await store.load() }
            if env.categoryStore.categories.isEmpty { await env.categoryStore.load() }
        }
    }

    // MARK: - Month switcher

    private var monthTitle: String {
        store.month.startDate().formatted(.dateTime.month(.wide).year())
    }

    private var monthSection: some View {
        Section {
            HStack {
                Button {
                    Task { await store.showPreviousMonth() }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous month")
                Spacer()
                Text(monthTitle)
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    Task { await store.showNextMonth() }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next month")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Summary

    /// Totals cover budgeted categories only, so one big unbudgeted transfer
    /// can't drown the "how are our budgets doing" signal. Spending outside
    /// any budget gets its own callout line instead.
    private func summarySection(_ rollup: MonthBudget) -> some View {
        let budgeted = rollup.entries.filter { $0.budgeted + $0.rolloverIn > 0 }
        let limit = budgeted.reduce(Money(0)) { $0 + $1.budgeted + $1.rolloverIn }
        let spent = budgeted.reduce(Money(0)) { $0 + $1.spent }
        let unbudgetedSpent = rollup.totalSpent - spent
        let available = limit - spent
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    summaryStat("Budgeted", limit)
                    Spacer()
                    summaryStat("Spent", spent)
                    Spacer()
                    summaryStat(available < 0 ? "Over" : "Left", abs(available),
                                color: available < 0 ? .red : .green)
                }
                if limit > 0 {
                    BudgetBar(fraction: fraction(spent, of: limit), overspent: available < 0)
                }
                if unbudgetedSpent > 0 {
                    Text("+ \(currency(unbudgetedSpent)) spent outside any budget")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryStat(_ label: String, _ amount: Money, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(currency(amount))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: - Categories

    private var categorySections: some View {
        ForEach(env.categoryStore.categoriesByGroup().filter { !$0.group.isIncome },
                id: \.group.id) { group, categories in
            Section(group.name) {
                ForEach(categories) { category in
                    Button {
                        editing = category
                    } label: {
                        BudgetCategoryRow(category: category,
                                          budget: store.budget(for: category.id),
                                          progress: store.progress(for: category.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One category's line: name, spent-vs-limit bar when budgeted, plain spending
/// when not, and a "Set budget" hint when the category is untouched.
private struct BudgetCategoryRow: View {
    let category: BudgetCategory
    let budget: Budget?
    let progress: BudgetProgress?

    private var limit: Money { (progress?.budgeted ?? budget?.amount ?? 0) + (progress?.rolloverIn ?? 0) }
    private var spent: Money { progress?.spent ?? 0 }
    private var available: Money { limit - spent }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon ?? "circle")
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(category.name)
                    if budget?.rolloverEnabled == true {
                        Image(systemName: "arrow.uturn.forward.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Rollover enabled")
                    }
                }
                if limit > 0 {
                    BudgetBar(fraction: fraction(spent, of: limit), overspent: available < 0)
                    Text("\(currency(spent)) of \(currency(limit))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        if limit > 0 {
            Text(available < 0 ? "\(currency(abs(available))) over" : "\(currency(available)) left")
                .font(.callout.monospacedDigit())
                .foregroundStyle(available < 0 ? .red : .green)
        } else if spent > 0 {
            Text("\(currency(spent)) spent")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text("Set budget")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Thin capsule progress bar. Green while under budget, red once over.
private struct BudgetBar: View {
    let fraction: Double
    let overspent: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(overspent ? Color.red : Color.green)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Editor for one category's monthly limit + rollover, presented as a sheet.
private struct SetBudgetSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let category: BudgetCategory

    /// Optional so a category with no budget starts as an empty field (typing
    /// into a preformatted "$0.00" would append after the decimals).
    @State private var amount: Money?
    @State private var rollover = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Monthly limit", value: $amount, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                    Toggle("Roll over unused budget", isOn: $rollover)
                } footer: {
                    Text("Rollover carries whatever is left over (or overspent) into next month's available amount.")
                }
                if let progress = env.budgetStore.progress(for: category.id), progress.spent != 0 {
                    Section {
                        LabeledContent("Spent this month", value: currency(progress.spent))
                        if progress.rolloverIn != 0 {
                            LabeledContent("Rolled in", value: currency(progress.rolloverIn))
                        }
                    }
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await env.budgetStore.setBudget(
                                categoryID: category.id, amount: amount ?? 0, rolloverEnabled: rollover)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(isSaving || (amount ?? 0) < 0)
                }
            }
            .onAppear {
                if let existing = env.budgetStore.budget(for: category.id) {
                    amount = existing.amount
                    rollover = existing.rolloverEnabled
                }
            }
        }
    }
}

// MARK: - Shared formatting

private func currency(_ amount: Money) -> String {
    amount.formatted(.currency(code: "USD").precision(.fractionLength(amount == amount.rounded() ? 0 : 2)))
}

private func fraction(_ spent: Money, of limit: Money) -> Double {
    guard limit > 0 else { return spent > 0 ? 1 : 0 }
    return (spent as NSDecimalNumber).doubleValue / (limit as NSDecimalNumber).doubleValue
}

private extension Money {
    func rounded() -> Money {
        var value = self
        var result = Money()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
