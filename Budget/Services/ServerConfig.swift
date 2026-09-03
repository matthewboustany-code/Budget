import Foundation

/// Where the app finds its backend. Mirrors FlightBag's `ServerConfig`: the
/// base URL is read from `UserDefaults` (key `serverBaseURL`), can be set for a
/// run with the `-serverBaseURL` launch argument so the simulator can point at
/// a local `swift run App serve`, and can be edited in Settings on a real
/// device — which is the only way a phone or iPad can reach a server, since
/// `localhost` there is the device itself.
public enum ServerConfig {
    static let defaultsKey = "serverBaseURL"

    /// Falls back to localhost, which is only useful in the Simulator.
    public static let fallbackURL = URL(string: "http://localhost:8080")!

    public static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let url = URL(string: raw) {
            return url
        }
        return fallbackURL
    }

    /// True when the URL is still the built-in localhost default, i.e. nothing
    /// has been configured for this install.
    public static var isUsingFallback: Bool {
        UserDefaults.standard.string(forKey: defaultsKey) == nil
    }

    /// Normalizes and validates user-entered text. Returns nil when it isn't a
    /// usable http(s) base URL, so Settings can reject it before saving.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    @discardableResult
    public static func setBaseURL(_ string: String) -> Bool {
        guard let url = normalize(string) else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: defaultsKey)
        return true
    }

    /// Drops the override and goes back to the localhost default.
    public static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
