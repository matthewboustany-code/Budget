import SwiftUI
import BudgetModels

/// Shared savings goals: both partners see and fund the same pots. The list
/// shows progress at a glance; the detail screen holds the contribution
/// ledger.
struct GoalsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var isAdding = false

    private var store: GoalsStore { env.goalsStore }

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            if store.goals.isEmpty && !store.isLoading {
                Section {
                    ContentUnavailableView {
                        Label("No goals yet", systemImage: "target")
                    } description: {
                        Text("Create a shared goal — a trip, an emergency fund — and both of you can add to it.")
                    } actions: {
                        Button("New Goal") { isAdding = true }
                    }
                }
            } else {
                Section {
                    ForEach(store.goals) { goal in
                        NavigationLink {
                            GoalDetailView(goalID: goal.id)
                        } label: {
                            GoalRow(goal: goal)
                        }
                    }
                }
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New goal")
            }
        }
        .sheet(isPresented: $isAdding) {
            GoalFormSheet()
                .presentationDetents([.medium])
        }
        .refreshable { await store.load() }
        .task {
            if store.goals.isEmpty { await store.load() }
        }
    }
}

/// One goal's line: icon, name, progress bar, saved-vs-target.
private struct GoalRow: View {
    let goal: Goal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: goal.icon ?? "target")
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.name)
                ProgressView(value: goal.progress)
                    .tint(goal.isComplete ? .green : .accentColor)
                Text("\(currency(goal.currentAmount)) of \(currency(goal.targetAmount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if goal.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Complete")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Detail: progress, deadline math, contribution ledger, add/withdraw.
private struct GoalDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let goalID: UUID

    @State private var detail: GoalDetailResponse?
    @State private var isContributing = false
    @State private var isEditing = false
    @State private var confirmDelete = false

    private var goal: Goal? { env.goalsStore.goals.first { $0.id == goalID } }

    var body: some View {
        List {
            if let goal {
                summarySection(goal)
                contributionsSection
            }
        }
        .navigationTitle(goal?.name ?? "Goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Edit Goal") { isEditing = true }
                    Button("Delete Goal", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Goal options")
            }
        }
        .sheet(isPresented: $isContributing) {
            ContributeSheet(goalID: goalID) { updated in detail = updated }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $isEditing) {
            GoalFormSheet(existing: goal)
                .presentationDetents([.medium])
        }
        .confirmationDialog("Delete this goal?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Goal", role: .destructive) {
                Task {
                    if await env.goalsStore.delete(goalID) { dismiss() }
                }
            }
        } message: {
            Text("Its contribution history goes with it. The money itself lives in your accounts and is not affected.")
        }
        .task { detail = await env.goalsStore.detail(goalID) }
    }

    private func summarySection(_ goal: Goal) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(currency(goal.currentAmount))
                        .font(.system(.title, design: .rounded).bold())
                    Text("of \(currency(goal.targetAmount))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: goal.icon ?? "target")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                ProgressView(value: goal.progress)
                    .tint(goal.isComplete ? .green : .accentColor)
                if goal.isComplete {
                    Label("Goal reached", systemImage: "party.popper")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text(remainingLabel(goal))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    isContributing = true
                } label: {
                    Label("Add Money", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    /// "X to go" plus, when there's a target date, the steady monthly amount
    /// that gets there on time.
    private func remainingLabel(_ goal: Goal) -> String {
        var label = "\(currency(goal.remaining)) to go"
        if let targetDate = goal.targetDate {
            let months = max(Calendar.current.dateComponents(
                [.month], from: Date(), to: targetDate).month ?? 0, 0)
            if months >= 1 {
                let perMonth = goal.remaining / Money(months)
                label += " · about \(currency(perMonth))/month until \(targetDate.formatted(.dateTime.month().year()))"
            } else {
                label += " · due \(targetDate.formatted(date: .abbreviated, time: .omitted))"
            }
        }
        return label
    }

    @ViewBuilder
    private var contributionsSection: some View {
        if let detail, !detail.contributions.isEmpty {
            Section("History") {
                ForEach(detail.contributions) { contribution in
                    ContributionRow(contribution: contribution,
                                    members: env.session.members)
                }
            }
        }
    }
}

/// One ledger entry: who, when, optional note, signed amount.
private struct ContributionRow: View {
    let contribution: GoalContribution
    let members: [HouseholdMember]

    private var memberName: String? {
        members.first { $0.id == contribution.memberID }?.displayName
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(memberName ?? "Contribution")
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(amountLabel)
                .monospacedDigit()
                .foregroundStyle(contribution.amount < 0 ? .red : .green)
        }
    }

    private var subtitle: String {
        var parts = [contribution.date.formatted(date: .abbreviated, time: .omitted)]
        if let note = contribution.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var amountLabel: String {
        (contribution.amount < 0 ? "−" : "+") + currency(abs(contribution.amount))
    }
}

/// Create or edit a goal. Pass `existing` to edit (name/target/date/icon).
private struct GoalFormSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    var existing: Goal?

    @State private var name = ""
    /// Optional so the field starts empty rather than "$0.00" (see BudgetView).
    @State private var target: Money?
    @State private var hasDeadline = false
    @State private var targetDate = Date()
    @State private var icon = "target"
    @State private var isSaving = false

    private static let icons = ["target", "airplane", "house", "car", "gift",
                                "heart", "graduationcap", "umbrella", "pawprint",
                                "figure.2", "sparkles", "banknote"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Hawaii trip)", text: $name)
                    TextField("Target amount", value: $target, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                }
                Section {
                    Toggle("Target date", isOn: $hasDeadline.animation())
                    if hasDeadline {
                        DatePicker("By", selection: $targetDate, in: Date()..., displayedComponents: .date)
                    }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                        ForEach(Self.icons, id: \.self) { symbol in
                            Button {
                                icon = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(icon == symbol ? Color.accentColor.opacity(0.2) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Goal" : "Edit Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { save() }
                        .disabled(isSaving
                                  || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (target ?? 0) <= 0)
                }
            }
            .onAppear {
                if let existing {
                    name = existing.name
                    target = existing.targetAmount
                    icon = existing.icon ?? "target"
                    if let date = existing.targetDate {
                        hasDeadline = true
                        targetDate = date
                    }
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let saved: Bool
            if let existing {
                saved = await env.goalsStore.update(existing.id, UpdateGoalRequest(
                    name: trimmed, targetAmount: target,
                    targetDate: hasDeadline ? targetDate : nil,
                    clearTargetDate: hasDeadline ? nil : true,
                    icon: icon)) != nil
            } else {
                saved = await env.goalsStore.create(CreateGoalRequest(
                    name: trimmed, targetAmount: target ?? 0,
                    targetDate: hasDeadline ? targetDate : nil,
                    icon: icon))
            }
            isSaving = false
            if saved { dismiss() }
        }
    }
}

/// Add to or withdraw from a goal.
private struct ContributeSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let goalID: UUID
    var onSaved: (GoalDetailResponse) -> Void

    @State private var amount: Money?
    @State private var isWithdrawal = false
    @State private var note = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $isWithdrawal) {
                        Text("Add").tag(false)
                        Text("Withdraw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Amount", value: $amount, format: .currency(code: "USD"))
                        .keyboardType(.decimalPad)
                    TextField("Note (optional)", text: $note)
                } footer: {
                    Text("This tracks progress toward the goal — it doesn't move money between accounts.")
                }
            }
            .navigationTitle(isWithdrawal ? "Withdraw" : "Add Money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || (amount ?? 0) <= 0)
                }
            }
        }
    }

    private func save() {
        guard let amount, amount > 0 else { return }
        isSaving = true
        Task {
            let signed = isWithdrawal ? -amount : amount
            let trimmedNote = note.trimmingCharacters(in: .whitespaces)
            if let updated = await env.goalsStore.contribute(
                goalID, amount: signed, note: trimmedNote.isEmpty ? nil : trimmedNote) {
                onSaved(updated)
                dismiss()
            }
            isSaving = false
        }
    }
}

private func currency(_ amount: Money) -> String {
    amount.formatted(.currency(code: "USD").precision(.fractionLength(amount == amount.rounded() ? 0 : 2)))
}

private extension Money {
    func rounded() -> Money {
        var value = self
        var result = Money()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
