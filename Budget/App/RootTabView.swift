import SwiftUI

/// Main tab shell. Uses the modern `Tab` API with `.sidebarAdaptable` so it
/// becomes a sidebar on iPad and a tab bar on iPhone (FlightBag's convention).
/// Bills, Goals, and Reports are reached from the Home dashboard rather than
/// crowding the tab bar.
struct RootTabView: View {
    enum TabID: String, Hashable { case home, accounts, transactions, budget, settings }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: TabID = LaunchArgs.value(for: "-startTab")
        .flatMap(TabID.init(rawValue:)) ?? .home

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: TabID.home) {
                NavigationStack { DashboardView() }
            }
            Tab("Accounts", systemImage: "building.columns.fill", value: TabID.accounts) {
                NavigationStack { AccountsView() }
            }
            Tab("Transactions", systemImage: "list.bullet.rectangle.fill", value: TabID.transactions) {
                NavigationStack { TransactionsView() }
            }
            Tab("Budget", systemImage: "chart.pie.fill", value: TabID.budget) {
                NavigationStack { BudgetView() }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: TabID.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await env.refreshStale() } }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if env.isOffline {
                Button {
                    Task { await env.householdStore.refresh() }
                } label: {
                    Label("Offline — showing saved data. Tap to retry.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(.orange.opacity(0.9))
                .foregroundStyle(.white)
            }
        }
    }
}
