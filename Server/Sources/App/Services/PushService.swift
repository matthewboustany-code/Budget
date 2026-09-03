import Vapor
import APNS
import APNSCore
import VaporAPNS

/// APNs delivery for bill reminders.
///
/// Push is optional infrastructure: when APNs isn't configured the server
/// behaves exactly as it did before (the reminder command logs and nothing
/// else), so a missing key is never a startup failure. That's deliberate —
/// a personal deployment should keep working when the key expires.
enum PushService {
    /// Wires `app.apns` when all four credentials are present. Returns whether
    /// push is live so callers can log the distinction once, at boot.
    ///
    /// **Both** the sandbox and production containers are registered from the
    /// same key — a token-based APNs key is not environment-specific, unlike
    /// the legacy certificates. Registering both is what lets `send` route each
    /// device to the host that actually minted its token.
    @discardableResult
    static func configure(_ app: Application) async -> Bool {
        let config = app.appConfig
        guard config.apnsConfigured,
              let keyID = config.apnsKeyID, let teamID = config.apnsTeamID,
              let p8 = config.apnsKeyP8, let topic = config.apnsTopic else {
            app.logger.notice("APNs not configured — bill reminders will log only.")
            return false
        }

        do {
            let authenticator = try APNSClientConfiguration.AuthenticationMethod.jwt(
                privateKey: .init(pemRepresentation: p8),
                keyIdentifier: keyID,
                teamIdentifier: teamID)
            // The default container follows APNS_ENV, and is what a token with
            // no recorded environment falls back to.
            // `isDefault` is precomputed: Vapor also has an `Environment`, so
            // comparing `environment == .production` inline resolves to the
            // wrong type.
            let containers: [(APNSContainers.ID, APNSEnvironment, Bool)] = [
                (.development, .development, !config.apnsUseProduction),
                (.production, .production, config.apnsUseProduction),
            ]
            for (id, environment, isDefault) in containers {
                await app.apns.containers.use(
                    APNSClientConfiguration(authenticationMethod: authenticator, environment: environment),
                    eventLoopGroupProvider: .shared(app.eventLoopGroup),
                    responseDecoder: JSONDecoder(),
                    requestEncoder: JSONEncoder(),
                    as: id,
                    isDefault: isDefault)
            }
            app.logger.info("APNs ready (topic \(topic), sandbox + production; default \(config.apnsUseProduction ? "production" : "sandbox"))")
            return true
        } catch {
            // A malformed key shouldn't take the whole server down; reminders
            // degrade to logging, and the reason is recorded.
            app.logger.error("APNs key rejected, push disabled: \(error)")
            return false
        }
    }

    /// Sends one alert to each token. Tokens APNs reports as permanently bad
    /// (`BadDeviceToken` / `Unregistered`) are pruned, so a reinstalled or
    /// deleted app stops being retried forever.
    static func send(alert title: String, body: String, threadID: String,
                     to tokens: [DeviceToken], on app: Application) async {
        guard !tokens.isEmpty, let topic = app.appConfig.apnsTopic else { return }
        let store = DeviceTokenStore(db: app.appDatabase.dbPool)

        for device in tokens {
            let notification = APNSAlertNotification(
                alert: .init(title: .raw(title), body: .raw(body)),
                expiration: .immediately,
                priority: .immediately,
                topic: topic,
                payload: EmptyPayload(),
                sound: .default,
                threadID: threadID)
            // Route by the environment the token was registered with: a
            // sandbox token is rejected outright by the production host, and
            // both kinds coexist as soon as there's a TestFlight build
            // alongside a development one.
            let container: APNSContainers.ID = device.environment == "production" ? .production : .development
            do {
                try await app.apns.client(container)
                    .sendAlertNotification(notification, deviceToken: device.token)
            } catch let error as APNSError where error.reason == .badDeviceToken || error.reason == .unregistered {
                app.logger.info("Pruning dead device token (\(error.reason.map(String.init(describing:)) ?? "unknown")).")
                try? await store.unregister(token: device.token)
            } catch {
                // One bad token must not stop the rest of the household's pushes.
                app.logger.warning("APNs send failed: \(error)")
            }
        }
    }
}

/// APNs requires a Codable payload; bill reminders carry no custom data.
struct EmptyPayload: Codable, Sendable {}
