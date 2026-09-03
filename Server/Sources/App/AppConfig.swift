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

    /// Universal link Plaid sends the user back to after an OAuth handoff to a
    /// bank. Must be registered in the Plaid dashboard for this environment and
    /// backed by an apple-app-site-association file, or Link rejects it. Left
    /// unset in sandbox, where no OAuth institutions are exercised.
    var plaidRedirectURI: String?

    /// SQLCipher passphrase for the database file. Required in production: the
    /// whole point is that a leaked volume or snapshot is not readable, and an
    /// optional-in-production setting is one that eventually isn't set.
    var dbEncryptionKey: String?

    /// When true, `POST /v1/auth/apple` accepts a dev token instead of a real
    /// Apple identity token, so the whole flow can be exercised on the
    /// simulator without an Apple Developer account. Never enable in production.
    var authDevMode: Bool

    /// APNs credentials for bill reminders. Push is **optional**: with these
    /// unset the server runs exactly as before and the reminder command just
    /// logs, which is why none of them are required by `validate`. All four
    /// must be present together for push to be considered configured.
    var apnsKeyID: String? = nil
    var apnsTeamID: String? = nil
    /// The .p8 signing key's contents (not a path) so it can be injected as a
    /// secret in compose without mounting a file.
    var apnsKeyP8: String? = nil
    /// The app's bundle id — APNs calls this the topic.
    var apnsTopic: String? = nil
    /// `production` sends to the real APNs host; anything else uses sandbox,
    /// which is what a development-signed build registers against.
    var apnsUseProduction: Bool = false

    var apnsConfigured: Bool {
        apnsKeyID?.isEmpty == false && apnsTeamID?.isEmpty == false
            && apnsKeyP8?.isEmpty == false && apnsTopic?.isEmpty == false
    }

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
            appleBundleID: Environment.get("APPLE_BUNDLE_ID") ?? "com.mbandhb.budget",
            sessionJWTSecret: Environment.get("SESSION_JWT_SECRET") ?? "dev-insecure-secret-change-me",
            plaidClientID: Environment.get("PLAID_CLIENT_ID") ?? "",
            plaidSecret: Environment.get("PLAID_SECRET") ?? "",
            plaidEnv: Environment.get("PLAID_ENV") ?? "sandbox",
            plaidProducts: (Environment.get("PLAID_PRODUCTS") ?? "transactions")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            plaidWebhookURL: Environment.get("PLAID_WEBHOOK_URL").flatMap { $0.isEmpty ? nil : $0 },
            plaidTokenEncKey: Environment.get("PLAID_TOKEN_ENC_KEY") ?? "",
            plaidRedirectURI: Environment.get("PLAID_REDIRECT_URI")?.nilIfBlank,
            dbEncryptionKey: Environment.get("BUDGET_DB_ENCRYPTION_KEY")?.nilIfBlank,
            // Dev auth defaults ON outside production so local runs "just work".
            authDevMode: devModeRequested ?? (env != .production),
            apnsKeyID: Environment.get("APNS_KEY_ID")?.nilIfBlank,
            apnsTeamID: Environment.get("APNS_TEAM_ID")?.nilIfBlank,
            // Compose/env can't carry raw newlines, so an escaped-newline form
            // is accepted and normalized here.
            apnsKeyP8: Environment.get("APNS_KEY_P8")?.nilIfBlank?
                .replacingOccurrences(of: "\\n", with: "\n"),
            apnsTopic: Environment.get("APNS_TOPIC")?.nilIfBlank
                ?? Environment.get("APPLE_BUNDLE_ID")?.nilIfBlank,
            apnsUseProduction: (Environment.get("APNS_ENV") ?? "sandbox").lowercased() == "production"
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
        let dbKey = config.dbEncryptionKey ?? ""
        if dbKey.isEmpty || dbKey.hasPrefix("change-me") || dbKey.count < 32 {
            throw ConfigError.missingSecret("BUDGET_DB_ENCRYPTION_KEY")
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
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
