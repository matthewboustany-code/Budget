import SwiftUI
import BudgetModels

/// Split one transaction across categories: rows of category + amount, a live
/// remainder, and Save only once the legs add up to the total (the server
/// enforces the same rule with `splitsBalance`).
///
/// Amounts are entered as positive magnitudes and stored with the parent's
/// sign, so a refund (a negative amount) splits the same way a purchase does.
struct SplitEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let transaction: Transaction
    let onSaved: (Transaction) -> Void

    private struct Leg: Identifiable {
        let id: UUID
        var categoryID: UUID?
        /// nil → empty field (a prefilled $0.00 appends typed digits after the decimals).
        var amount: Money?
    }

    @State private var legs: [Leg]
    @State private var isSaving = false

    init(transaction: Transaction, onSaved: @escaping (Transaction) -> Void) {
        self.transaction = transaction
        self.onSaved = onSaved
        let total = abs(transaction.amount)
        if transaction.isSplit {
            _legs = State(initialValue: transaction.splits.map {
                Leg(id: $0.id, categoryID: $0.categoryID, amount: abs($0.amount))
            })
        } else {
            // Start from the whole charge in its current category plus one empty leg.
            _legs = State(initialValue: [
                Leg(id: UUID(), categoryID: transaction.categoryID, amount: total),
                Leg(id: UUID(), categoryID: nil, amount: nil),
            ])
        }
    }

    private var total: Money { abs(transaction.amount) }
    private var allocated: Money { legs.reduce(Money(0)) { $0 + ($1.amount ?? 0) } }
    private var remainder: Money { total - allocated }

    private var canSave: Bool {
        legs.count >= 2 && remainder == 0 && !isSaving
            && legs.allSatisfy { $0.categoryID != nil && ($0.amount ?? 0) > 0 }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Total", value: currency(total))
                LabeledContent("Remaining") {
                    Text(remainder == 0 ? "Balanced" : currency(remainder))
                        .monospacedDigit()
                        .foregroundStyle(remainder == 0 ? .green : .red)
                }
            }

            ForEach($legs) { $leg in
                Section {
                    Picker("Category", selection: $leg.categoryID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(env.categoryStore.categoriesByGroup(), id: \.group.id) { entry in
                            Section(entry.group.name) {
                                ForEach(entry.categories) { category in
                                    Label(category.name, systemImage: category.icon ?? "tag")
                                        .tag(Optional(category.id))
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("$0.00", value: $leg.amount, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    if legs.count > 2 {
                        Button("Remove", role: .destructive) { legs.removeAll { $0.id == leg.id } }
                    }
                }
            }

            Section {
                Button {
                    // A new leg takes whatever is left, the common case being "the rest".
                    legs.append(Leg(id: UUID(), categoryID: nil, amount: remainder > 0 ? remainder : nil))
                } label: { Label("Add category", systemImage: "plus") }
                if transaction.isSplit {
                    Button("Remove split", role: .destructive) { Task { await save([]) } }
                }
            }
        }
        .navigationTitle("Split")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let sign: Money = transaction.amount < 0 ? -1 : 1
                    let splits = legs.map {
                        TransactionSplit(id: $0.id, categoryID: $0.categoryID, amount: ($0.amount ?? 0) * sign)
                    }
                    Task { await save(splits) }
                }
                .disabled(!canSave)
            }
        }
    }

    private func save(_ splits: [TransactionSplit]) async {
        isSaving = true
        defer { isSaving = false }
        if let updated = await env.transactionStore.update(transaction.id, .init(splits: splits)) {
            onSaved(updated)
            dismiss()
        }
    }

    private func currency(_ amount: Money) -> String {
        amount.formatted(.currency(code: "USD"))
    }
}
