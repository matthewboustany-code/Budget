import Foundation

/// Where the app finds its backend. Mirrors FlightBag's `ServerConfig`: the
/// base URL is read from `UserDefaults` (key `serverBaseURL`), can be set for a
/// run with the `-serverBaseURL` launch argument so the simulator can point at
/// a local `swift run App serve`, and can be edited in Settings on a real
/// device — which a self-hoster pointing at their own box still needs, since
/// `localhost` on a phone is the device itself.
public enum ServerConfig {
    static let defaultsKey = "serverBaseURL"

    /// The deployment this app ships against. It used to be
    /// `http://localhost:8080`, which is reachable only from the Simulator —
    /// on a phone that is the phone, so a fresh install could never connect.
    /// Point elsewhere with `-serverBaseURL` (Simulator) or Settings › Server.
    public static let fallbackURL = URL(string: "https://budget.mbandhb.com")!

    public static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let url = URL(string: raw) {
            return url
        }
        return fallbackURL
    }

    /// True when the URL is still the built-in default, i.e. nothing has been
    /// configured for this install.
    public static var isUsingFallback: Bool {
        UserDefaults.standard.string(forKey: defaultsKey) == nil
    }

    /// Normalizes and validates user-entered text. Returns nil when it isn't a
    /// usable http(s) base URL, so Settings can reject it before saving.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        // Default to https. A bare host used to become http://, which ATS
        // then refused for any non-local server ("requires the use of a
        // secure connection") — and the failure names ATS, not the scheme
        // this function chose, so it reads as an app bug rather than a typo.
        // A LAN server over plain http still works by typing the scheme.
        if !text.contains("://") { text = "https://" + text }
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
