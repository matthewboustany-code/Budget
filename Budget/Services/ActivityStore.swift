import Foundation
import Observation
import BudgetModels

/// The partner activity feed: comments and reactions your household partner
/// left on transactions, plus the unread count behind the dashboard's bell.
///
/// "Unread" is a local, per-device notion — a last-seen timestamp in
/// `UserDefaults` — not server state. Two devices marking each other read
/// would need a sync protocol for something a glance already resolves, and the
/// server stays free of per-device bookkeeping.
@MainActor
@Observable
final class ActivityStore {
    private let api: APIClient
    private let defaults: UserDefaults

    private static let lastSeenKey = "activity.lastSeenAt"

    var events: [ActivityEvent] = []
    var isLoading = false
    private(set) var lastLoaded: Date?
    var errorMessage: String?

    /// The newest event the user has actually looked at.
    private(set) var lastSeenAt: Date?

    init(api: APIClient, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.lastSeenKey)
        lastSeenAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        // Last-known feed for the first frame; `load()` refreshes it.
        let cached: ActivityFeedResponse? = api.cached("v1/activity")
        events = cached?.events ?? []
    }

    /// Events newer than the last visit. Recomputed rather than stored, so the
    /// badge clears the instant `markSeen()` moves the timestamp.
    var unreadCount: Int {
        guard let lastSeenAt else { return events.count }
        return events.filter { $0.createdAt > lastSeenAt }.count
    }

    func isUnread(_ event: ActivityEvent) -> Bool {
        guard let lastSeenAt else { return true }
        return event.createdAt > lastSeenAt
    }

    /// Loads the whole recent feed, not just `?since=` — the badge needs the
    /// unread slice but the screen behind it needs history, and one request
    /// serves both.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response: ActivityFeedResponse = try await api.get("v1/activity")
            events = response.events
            errorMessage = nil
            lastLoaded = Date()
        } catch {
            errorMessage = (error as? APIClientError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Marks everything currently loaded as read. Anchored on the newest event
    /// rather than `Date()`: clock skew between the server and the device
    /// would otherwise leave a just-arrived comment permanently unread.
    func markSeen() {
        guard let newest = events.map(\.createdAt).max() else { return }
        guard newest > (lastSeenAt ?? .distantPast) else { return }
        lastSeenAt = newest
        defaults.set(newest.timeIntervalSince1970, forKey: Self.lastSeenKey)
    }
}
