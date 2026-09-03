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
            let environment: APNSEnvironment = config.apnsUseProduction ? .production : .development
            await app.apns.containers.use(
                APNSClientConfiguration(authenticationMethod: authenticator, environment: environment),
                eventLoopGroupProvider: .shared(app.eventLoopGroup),
                responseDecoder: JSONDecoder(),
                requestEncoder: JSONEncoder(),
                as: .default)
            app.logger.info("APNs ready (topic \(topic), \(config.apnsUseProduction ? "production" : "sandbox"))")
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
            do {
                try await app.apns.client.sendAlertNotification(notification, deviceToken: device.token)
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
