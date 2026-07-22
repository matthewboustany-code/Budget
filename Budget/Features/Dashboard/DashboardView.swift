import SwiftUI
import BudgetModels

/// P0 home screen: a connection banner proving app↔server connectivity, plus
/// entry points to the not-yet-built features. Phase 6 replaces this with the
/// Monarch-style dashboard (net worth, cash flow, budget summary, bills).
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            if let netWorth = env.accountStore.netWorth {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Net worth").font(.subheadline).foregroundStyle(.secondary)
                            Text(currency(netWorth.current.net))
                                .font(.system(.title, design: .rounded).bold())
                        }
                        Spacer()
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title)
                            .foregroundStyle(.tint)
                    }
                }
            }

            Section("Backend") {
                ConnectionRow(status: env.connectionStatus)
                Button("Recheck connection") {
                    Task { await env.checkConnection() }
                }
            }

            Section("Features") {
                NavigationLink { BillsView() } label: {
                    Label("Bills & Recurring", systemImage: "calendar")
                }
                NavigationLink { GoalsView() } label: {
                    Label("Goals", systemImage: "target")
                }
                NavigationLink { ReportsView() } label: {
                    Label("Reports", systemImage: "chart.bar.xaxis")
                }
            }
        }
        .navigationTitle("Budget")
    }
}

struct ConnectionRow: View {
    let status: AppEnvironment.ConnectionStatus

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(status.label)
                .font(.callout)
        }
    }

    private var symbol: String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .ok: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}
