import Foundation
import Observation
import UserNotifications
import UIKit
import BudgetModels

/// Registers this device for bill-reminder pushes.
///
/// The flow is: ask the user, ask APNs for a token, hand the token to our
/// server. Re-registering on every launch is intentional — APNs may reissue a
/// token at any time and the app can't tell a new one from a repeat, so the
/// server upsert is what keeps the table honest.
@MainActor
@Observable
final class PushRegistrar {
    /// Posted by the app delegate when APNs hands back a token.
    static let didReceiveTokenNotification = Notification.Name("BudgetDidReceiveAPNsToken")

    private let api: APIClient
    // `nonisolated(unsafe)` so `deinit` can unregister: it's assigned once in
    // init and only ever read there and in deinit, so there's no concurrent
    // access to guard against.
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    /// The last token we successfully sent, so a relaunch with an unchanged
    /// token doesn't re-POST on every foreground.
    private var lastRegistered: String?

    private(set) var authorizationDenied = false

    init(api: APIClient) {
        self.api = api
        observer = NotificationCenter.default.addObserver(
            forName: Self.didReceiveTokenNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let data = note.object as? Data else { return }
            MainActor.assumeIsolated { self?.send(tokenData: data) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }


    /// Asks for notification permission, then registers with APNs if granted.
    /// Declining is a normal outcome, not an error: reminders are a
    /// convenience and the rest of the app is unaffected.
    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationDenied = !granted
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            authorizationDenied = true
        }
    }

    /// Forgets this device server-side. Called on sign-out so a shared device
    /// stops receiving the previous user's reminders.
    func unregister() async {
        guard let token = lastRegistered else { return }
        lastRegistered = nil
        try? await api.delete("v1/devices/\(token)")
    }

    private func send(tokenData: Data) {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        guard token != lastRegistered else { return }
        Task {
            do {
                let _: Empty = try await api.post(
                    "v1/devices",
                    body: RegisterDeviceRequest(token: token, environment: Self.apnsEnvironment()))
                lastRegistered = token
            } catch {
                // Non-fatal: reminders are a convenience, and the next launch
                // re-registers. Don't surface this to the user.
            }
        }
    }

    /// Which APNs host minted this token. Read from the embedded provisioning
    /// profile's `aps-environment` rather than guessed from `#if DEBUG`:
    /// TestFlight builds are Release but still... production, while a Release
    /// build signed with a development profile is sandbox. Guessing gets this
    /// backwards and the push silently never arrives.
    static func apnsEnvironment() -> String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let range = text.range(of: "<key>aps-environment</key>") else {
            return "production"
        }
        let tail = text[range.upperBound...].prefix(200)
        return tail.contains("development") ? "sandbox" : "production"
        #endif
    }
}
