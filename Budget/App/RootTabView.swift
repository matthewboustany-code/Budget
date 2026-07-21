import SwiftUI

/// Main tab shell. Uses the modern `Tab` API with `.sidebarAdaptable` so it
/// becomes a sidebar on iPad and a tab bar on iPhone (FlightBag's convention).
/// Bills, Goals, and Reports are reached from the Home dashboard rather than
/// crowding the tab bar.
struct RootTabView: View {
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack { DashboardView() }
            }
            Tab("Accounts", systemImage: "building.columns.fill") {
                NavigationStack { AccountsView() }
            }
            Tab("Transactions", systemImage: "list.bullet.rectangle.fill") {
                NavigationStack { TransactionsView() }
            }
            Tab("Budget", systemImage: "chart.pie.fill") {
                NavigationStack { BudgetView() }
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
