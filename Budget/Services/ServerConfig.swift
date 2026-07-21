import Foundation

/// Where the app finds its backend. Mirrors FlightBag's `ServerConfig`: the
/// base URL is read from `UserDefaults` (key `serverBaseURL`) and can be set
/// for a run with the `-serverBaseURL` launch argument, so the simulator can
/// point at a local `swift run App serve` instance.
public enum ServerConfig {
    static let defaultsKey = "serverBaseURL"

    /// Falls back to localhost for development. Ship builds should set this via
    /// Settings or a build-configuration default.
    public static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:8080")!
    }

    public static func setBaseURL(_ string: String) {
        UserDefaults.standard.set(string, forKey: defaultsKey)
    }
}
