import SwiftUI

/// Main tab shell. Uses the modern `Tab` API with `.sidebarAdaptable` so it
/// becomes a sidebar on iPad and a tab bar on iPhone (FlightBag's convention).
/// Bills, Goals, and Reports are reached from the Home dashboard rather than
/// crowding the tab bar.
struct RootTabView: View {
    enum TabID: String, Hashable { case home, accounts, transactions, budget, settings }

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
    }
}
