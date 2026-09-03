import Foundation
import Vapor

/// A fixed-window rate limiter for the handful of unauthenticated or
/// guess-able endpoints.
///
/// Why this exists: redeeming an invite code adds you to a household and hands
/// you its entire financial history, and `POST /v1/household/join` will happily
/// be called as fast as the network allows. Without a limit, an attacker who
/// signs in with any Apple ID can grind codes until one lands. The codes are
/// also 50 bits now (see `HouseholdStore.generateCode`), but entropy alone
/// shouldn't be the only thing standing between a stranger and a couple's bank
/// records — an attacker who gets to make unlimited free guesses has been given
/// far too much room, whatever the keyspace.
///
/// Deliberately in-memory: this is a single-instance, two-person server, so a
/// shared store would be complexity with no benefit. Counters reset on restart,
/// which is acceptable — a restart is not something an attacker can trigger.
actor RateLimiter {
    struct Rule: Sendable {
        let limit: Int
        let window: TimeInterval
    }

    private struct Bucket {
        var count: Int
        var resetAt: Date
    }

    private var buckets: [String: Bucket] = [:]
    /// Bounds memory against an attacker rotating the key (e.g. spoofed IPs).
    /// Well above anything real traffic produces for these few endpoints.
    private let maxBuckets = 10_000

    /// Records a hit. Returns nil when allowed, or the seconds to wait when the
    /// caller is over the limit.
    func consume(key: String, rule: Rule, now: Date = Date()) -> TimeInterval? {
        if var bucket = buckets[key], bucket.resetAt > now {
            guard bucket.count < rule.limit else {
                return bucket.resetAt.timeIntervalSince(now)
            }
            bucket.count += 1
            buckets[key] = bucket
            return nil
        }
        if buckets.count >= maxBuckets { sweep(now: now) }
        buckets[key] = Bucket(count: 1, resetAt: now.addingTimeInterval(rule.window))
        return nil
    }

    /// Drops expired buckets; if they were all still live, clears the lot
    /// rather than growing without bound.
    private func sweep(now: Date) {
        buckets = buckets.filter { $0.value.resetAt > now }
        if buckets.count >= maxBuckets { buckets.removeAll() }
    }
}

extension Application {
    private struct RateLimiterKey: StorageKey { typealias Value = RateLimiter }

    var rateLimiter: RateLimiter {
        if let existing = storage[RateLimiterKey.self] { return existing }
        let created = RateLimiter()
        storage[RateLimiterKey.self] = created
        return created
    }
}

/// Applies a `RateLimiter.Rule` to a route group, keyed by client identity.
struct RateLimitMiddleware: AsyncMiddleware {
    let rule: RateLimiter.Rule
    /// Distinguishes buckets so two limited routes don't share a counter.
    let name: String

    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Prefer the authenticated user, which an attacker can't rotate for
        // free; fall back to the peer address. Behind the Cloudflare tunnel the
        // client address is the tunnel's, so the header is what carries the
        // real origin — see `clientKey`.
        let key = "\(name):\(clientKey(req))"
        if let retryAfter = await req.application.rateLimiter.consume(key: key, rule: rule) {
            req.logger.warning("Rate limit hit for \(name)")
            let response = Response(status: .tooManyRequests)
            response.headers.replaceOrAdd(name: .retryAfter, value: String(Int(retryAfter.rounded(.up))))
            try response.content.encode(ErrorResponse(
                error: true,
                reason: "Too many attempts. Try again in a moment."))
            return response
        }
        return try await next.respond(to: req)
    }

    private func clientKey(_ req: Request) -> String {
        if let user = req.authenticatedUser { return "user:\(user.id.uuidString)" }
        // CF-Connecting-IP is set by Cloudflare and, because the origin is only
        // reachable through the tunnel, cannot be spoofed by the client.
        if let cf = req.headers.first(name: "CF-Connecting-IP") { return "ip:\(cf)" }
        return "ip:\(req.remoteAddress?.ipAddress ?? "unknown")"
    }
}

private struct ErrorResponse: Content {
    var error: Bool
    var reason: String
}
