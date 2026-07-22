import Foundation
import Observation

/// Dependency container injected at the app root. Features reach services
/// through this — never through singletons — so previews and tests can swap
/// implementations. Same pattern as FlightBag's `AppEnvironment`.
@MainActor
@Observable
final class AppEnvironment {
    let session: Session
    let api: APIClient
    let authStore: AuthStore
    let householdStore: HouseholdStore
    let accountStore: AccountStore
    let transactionStore: TransactionStore
    let categoryStore: CategoryStore
    let budgetStore: BudgetStore
    let billsStore: BillsStore
    let goalsStore: GoalsStore
    let reportsStore: ReportsStore

    /// Result of the last `/health` probe, shown in Settings.
    var connectionStatus: ConnectionStatus = .unknown
    /// True while the launch-time `/me` refresh is in flight, so the UI can show
    /// a splash instead of flashing the onboarding screen.
    var isBootstrapping = false

    init(session: Session? = nil, api: APIClient? = nil) {
        let session = session ?? Session()
        let api = api ?? APIClient(tokenProvider: session.tokenReader)
        self.session = session
        self.api = api
        self.authStore = AuthStore(api: api, session: session)
        self.householdStore = HouseholdStore(api: api, session: session)
        self.accountStore = AccountStore(api: api)
        self.transactionStore = TransactionStore(api: api)
        self.categoryStore = CategoryStore(api: api)
        self.budgetStore = BudgetStore(api: api)
        self.billsStore = BillsStore(api: api)
        self.goalsStore = GoalsStore(api: api)
        self.reportsStore = ReportsStore(api: api)
    }

    /// On launch, if a session token exists, refresh identity + household from
    /// the server (signs out on 401). In DEBUG, honors scripted launch args.
    func bootstrap() async {
        #if DEBUG
        if LaunchArgs.has("-resetSession") { session.signOut() }
        if !session.isSignedIn, let name = LaunchArgs.value(for: "-autoDevSignIn") {
            isBootstrapping = true
            await authStore.devSignIn(as: name)
            isBootstrapping = false
        }
        #endif
        guard session.isSignedIn else { return }
        isBootstrapping = true
        await householdStore.refresh()
        isBootstrapping = false
        if session.household != nil {
            await accountStore.load()
            await categoryStore.load()
        }
    }

    enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case ok(Date)
        case failed(String)

        var label: String {
            switch self {
            case .unknown: return "Not checked"
            case .checking: return "Checking…"
            case .ok(let t): return "Connected (\(t.formatted(date: .omitted, time: .standard)))"
            case .failed(let m): return "Failed: \(m)"
            }
        }
    }

    /// Connectivity probe used by the dashboard/settings banner.
    func checkConnection() async {
        connectionStatus = .checking
        do {
            let health: HealthCheck = try await api.get("v1/health")
            connectionStatus = health.database ? .ok(health.time) : .failed("Database degraded")
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}

/// Mirror of the server's `HealthResponse`.
struct HealthCheck: Decodable {
    var status: String
    var database: Bool
    var time: Date
}
