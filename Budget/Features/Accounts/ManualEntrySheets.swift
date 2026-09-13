import SwiftUI
import BudgetModels

/// Create a manual account — cash, a bank Plaid doesn't support, a loan to a
/// friend. Its balance is whatever the owner enters; nothing syncs it.
struct ManualAccountSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: AccountType = .cash
    /// Optional so the field starts empty (typing into a prefilled "$0.00"
    /// appends after the decimals).
    @State private var balance: Money?
    @State private var isPrivate = false
    @State private var isSaving = false

    private static let types: [AccountType] = [.cash, .checking, .savings, .creditCard, .loan, .investment, .other]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(Self.types, id: \.self) { Text($0.groupTitle).tag($0) }
                }
                TextField(type.isLiability ? "Amount owed" : "Balance",
                          value: $balance, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)
                Toggle("Private (hide from partner)", isOn: $isPrivate)
            }
            .navigationTitle("Manual account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isSaving = true
                        Task {
                            let saved = await env.accountStore.createManualAccount(CreateManualAccountRequest(
                                name: name, type: type, visibility: isPrivate ? .private : .shared,
                                currentBalance: balance ?? 0))
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Add a transaction to a manual account. It doesn't move the account's
/// balance — that's set on the account, just as a linked bank's balance and
/// its transactions arrive separately.
struct ManualTransactionSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var name = ""
    @State private var amount: Money?
    @State private var isIncome = false
    @State private var date = Date()
    @State private var categoryID: UUID?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Description", text: $name)
                TextField("Amount", value: $amount, format: .currency(code: "USD"))
                    .keyboardType(.decimalPad)
                Toggle("Money in", isOn: $isIncome)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Category", selection: $categoryID) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(env.categoryStore.categoriesByGroup(), id: \.group.id) { entry in
                        Section(entry.group.name) {
                            ForEach(entry.categories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isSaving = true
                        // Outflows positive, inflows negative — Plaid's convention.
                        let magnitude = abs(amount ?? 0)
                        let request = CreateTransactionRequest(
                            accountID: account.id, amount: isIncome ? -magnitude : magnitude,
                            date: date, name: name, categoryID: categoryID)
                        Task {
                            let saved = await env.transactionStore.addManual(request)
                            isSaving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty || (amount ?? 0) == 0)
                }
            }
            .task { if env.categoryStore.isStale() { await env.categoryStore.load() } }
        }
    }
}
