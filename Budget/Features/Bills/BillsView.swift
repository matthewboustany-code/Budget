import SwiftUI
import BudgetModels

/// Bills & recurring: what's due soon (projected from detected series) and the
/// series themselves. Pull to refresh re-runs detection server-side; flipping
/// a series off ("not a bill") removes its projected occurrences everywhere.
struct BillsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var mode: Mode = .upcoming

    private enum Mode: String, CaseIterable {
        case upcoming = "Upcoming"
        case recurring = "Recurring"
    }

    private var store: BillsStore { env.billsStore }

    var body: some View {
        List {
            Section {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if let error = store.errorMessage {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            switch mode {
            case .upcoming: upcomingSections
            case .recurring: recurringSections
            }
        }
        .navigationTitle("Bills")
        .refreshable { await store.redetect() }
        .task {
            if store.series.isEmpty { await store.load() }
        }
    }

    // MARK: - Upcoming

    @ViewBuilder
    private var upcomingSections: some View {
        let overdue = store.bills.filter { $0.status == .overdue }
        let upcoming = store.bills.filter { $0.status != .overdue }
        if store.bills.isEmpty {
            emptyState("No upcoming bills",
                       message: "Bills appear here once recurring charges are detected in your transactions.")
        } else {
            if !overdue.isEmpty {
                Section("Overdue") {
                    ForEach(overdue) { BillRow(bill: $0) }
                }
            }
            if !upcoming.isEmpty {
                Section(overdue.isEmpty ? "Next 30 days" : "Upcoming") {
                    ForEach(upcoming) { BillRow(bill: $0) }
                }
                monthTotalFooter(upcoming: upcoming, overdue: overdue)
            }
        }
    }

    private func monthTotalFooter(upcoming: [Bill], overdue: [Bill]) -> some View {
        let total = (upcoming + overdue).reduce(Money(0)) { $0 + $1.amount }
        return Section {
            LabeledContent("Total due") {
                Text(currency(total)).monospacedDigit().fontWeight(.semibold)
            }
        }
    }

    // MARK: - Recurring

    @ViewBuilder
    private var recurringSections: some View {
        let active = store.series.filter(\.isActive)
        let inactive = store.series.filter { !$0.isActive }
        if store.series.isEmpty {
            emptyState("Nothing recurring yet",
                       message: "Once a merchant shows up several times at a steady rhythm, it appears here. Pull down to re-scan.")
        } else {
            if !active.isEmpty {
                Section("Detected") {
                    ForEach(active) { series in
                        RecurringRow(series: series)
                    }
                }
            }
            if !inactive.isEmpty {
                Section("Turned off") {
                    ForEach(inactive) { series in
                        RecurringRow(series: series)
                    }
                }
            }
        }
    }

    private func emptyState(_ title: String, message: String) -> some View {
        Section {
            ContentUnavailableView {
                Label(title, systemImage: "calendar.badge.clock")
            } description: {
                Text(message)
            }
        }
    }
}

/// One projected occurrence: name, due date (relative), amount.
private struct BillRow: View {
    let bill: Bill

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(bill.name)
                Text(dueLabel)
                    .font(.caption)
                    .foregroundStyle(bill.status == .overdue ? .red : .secondary)
            }
            Spacer()
            Text(currency(bill.amount))
                .monospacedDigit()
                .foregroundStyle(bill.status == .overdue ? .red : .primary)
        }
    }

    private var dueLabel: String {
        let days = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: bill.dueDate)).day ?? 0
        switch days {
        case ..<0: return "Due \(bill.dueDate.formatted(date: .abbreviated, time: .omitted)) — overdue"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due \(bill.dueDate.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

/// One series: name, cadence + next date, average amount, active toggle.
/// Income series (paychecks) show but have no bills, so the toggle is the
/// only control they need.
private struct RecurringRow: View {
    @Environment(AppEnvironment.self) private var env
    let series: RecurringSeries

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(series.name)
                    if series.isIncome {
                        Text("Income")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(currency(abs(series.averageAmount)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { series.isActive },
                set: { newValue in
                    Task { await env.billsStore.setActive(series.id, newValue) }
                }))
                .labelsHidden()
                .accessibilityLabel("Treat \(series.name) as recurring")
        }
    }

    private var subtitle: String {
        var parts = [cadenceLabel]
        if series.isActive, let next = series.nextDate {
            parts.append("next \(next.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private var cadenceLabel: String {
        switch series.cadence {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        case .irregular: return "Irregular"
        }
    }
}

private func currency(_ amount: Money) -> String {
    amount.formatted(.currency(code: "USD"))
}
