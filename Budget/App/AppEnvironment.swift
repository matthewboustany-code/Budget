import Foundation
import Observation

/// Dependency container injected at the app root. Features reach services
/// through this — never through singletons — so previews and tests can swap
/// implementations. Same pattern as FlightBag's `AppEnvironment`.
///
/// Feature stores (accounts, transactions, budgets, …) are added to this
/// container as their phases land; P0 wires the session, API client, and a
/// lightweight connection check.
@MainActor
@Observable
final class AppEnvironment {
    let session: Session
    let api: APIClient

    /// Result of the last `/health` probe, shown in Settings during bring-up.
    var connectionStatus: ConnectionStatus = .unknown

    init(session: Session? = nil, api: APIClient? = nil) {
        let session = session ?? Session()
        self.session = session
        self.api = api ?? APIClient(tokenProvider: session.tokenReader)
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

    /// P0 connectivity probe: confirms the app can reach the backend.
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
