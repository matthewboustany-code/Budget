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
    let pushRegistrar: PushRegistrar

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
        self.pushRegistrar = PushRegistrar(api: api)
        // One place turns an expired session into a sign-out, whichever
        // request discovers it.
        api.onUnauthorized = { [weak session] in session?.signOut() }
        // Changing the server URL signs out too, so this covers both.
        session.onSignOut = { [weak api] in api?.cache.clear() }
    }

    /// The server was unreachable at the last `/me`; the UI is running on the
    /// cached household.
    var isOffline: Bool { householdStore.isOffline }

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
        await authStore.refreshSessionIfNeeded()
        isBootstrapping = true
        await householdStore.refresh()
        isBootstrapping = false
        if session.household != nil {
            await accountStore.load()
            await categoryStore.load()
            // Only ask for notifications once the user is actually set up —
            // prompting on the sign-in screen asks for a permission that has
            // nothing to explain it yet.
            await pushRegistrar.requestAuthorizationAndRegister()
        }
    }

    /// On returning to the foreground, reload whatever has gone stale. A
    /// visible tab's `.task` doesn't re-run on foreground, so without this an
    /// app left open overnight shows yesterday's numbers until pulled.
    func refreshStale() async {
        guard session.isSignedIn, session.household != nil else { return }
        await authStore.refreshSessionIfNeeded()
        await householdStore.refresh()   // also clears the offline banner
        if accountStore.isStale() { await accountStore.load() }
        if transactionStore.isStale() { await transactionStore.load() }
        if reportsStore.isStale() {
            await reportsStore.load()
            await budgetStore.loadCurrentMonth()
        }
        if budgetStore.isStale() { await budgetStore.load() }
        if billsStore.isStale() { await billsStore.load() }
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
