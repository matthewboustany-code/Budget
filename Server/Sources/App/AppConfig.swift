import Vapor

/// Server configuration loaded once from the environment (`.env`). Held on the
/// `Application` so routes and middleware can read it without re-parsing env.
struct AppConfig: Sendable {
    var appleBundleID: String
    var sessionJWTSecret: String

    var plaidClientID: String
    var plaidSecret: String
    var plaidEnv: String
    var plaidProducts: [String]
    var plaidWebhookURL: String?
    var plaidTokenEncKey: String

    /// When true, `POST /v1/auth/apple` accepts a dev token instead of a real
    /// Apple identity token, so the whole flow can be exercised on the
    /// simulator without an Apple Developer account. Never enable in production.
    var authDevMode: Bool

    static func load(_ env: Environment) -> AppConfig {
        AppConfig(
            appleBundleID: Environment.get("APPLE_BUNDLE_ID") ?? "Me.Budget",
            sessionJWTSecret: Environment.get("SESSION_JWT_SECRET") ?? "dev-insecure-secret-change-me",
            plaidClientID: Environment.get("PLAID_CLIENT_ID") ?? "",
            plaidSecret: Environment.get("PLAID_SECRET") ?? "",
            plaidEnv: Environment.get("PLAID_ENV") ?? "sandbox",
            plaidProducts: (Environment.get("PLAID_PRODUCTS") ?? "transactions")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            plaidWebhookURL: Environment.get("PLAID_WEBHOOK_URL").flatMap { $0.isEmpty ? nil : $0 },
            plaidTokenEncKey: Environment.get("PLAID_TOKEN_ENC_KEY") ?? "",
            // Dev auth defaults ON outside production so local runs "just work".
            authDevMode: (Environment.get("AUTH_DEV_MODE").map { $0 == "1" || $0.lowercased() == "true" })
                ?? (env != .production)
        )
    }
}

extension Application {
    private struct AppConfigKey: StorageKey { typealias Value = AppConfig }
    var appConfig: AppConfig {
        get {
            guard let c = storage[AppConfigKey.self] else {
                fatalError("AppConfig not loaded. Call configure(app) first.")
            }
            return c
        }
        set { storage[AppConfigKey.self] = newValue }
    }
}

extension Request {
    var appConfig: AppConfig { application.appConfig }
}
