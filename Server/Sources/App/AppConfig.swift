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

    /// Refused at startup rather than discovered in an incident report.
    enum ConfigError: Error, CustomStringConvertible {
        case missingSecret(String)
        case devModeInProduction

        var description: String {
            switch self {
            case .missingSecret(let name):
                return "\(name) must be set to a real value in production (see Server/.env.example)."
            case .devModeInProduction:
                return "AUTH_DEV_MODE must not be enabled in production — it accepts unauthenticated sign-ins."
            }
        }
    }

    static func load(_ env: Environment) throws -> AppConfig {
        let devModeRequested = Environment.get("AUTH_DEV_MODE")
            .map { $0 == "1" || $0.lowercased() == "true" }

        let config = AppConfig(
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
            authDevMode: devModeRequested ?? (env != .production)
        )

        try validate(config, env: env, devModeRequested: devModeRequested)
        return config
    }

    /// Production fail-fast: a finance server must not boot on placeholder
    /// secrets. The dev defaults exist purely so local runs work. Split from
    /// `load` so tests can exercise the rules without touching process env.
    static func validate(_ config: AppConfig, env: Environment,
                         devModeRequested: Bool?) throws {
        guard env == .production else { return }
        if devModeRequested == true { throw ConfigError.devModeInProduction }
        if config.sessionJWTSecret == "dev-insecure-secret-change-me"
            || config.sessionJWTSecret.count < 32 {
            throw ConfigError.missingSecret("SESSION_JWT_SECRET")
        }
        if config.plaidTokenEncKey.isEmpty
            || config.plaidTokenEncKey.hasPrefix("change-me") {
            throw ConfigError.missingSecret("PLAID_TOKEN_ENC_KEY")
        }
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
