import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

@Suite("Invite codes & rate limiting", .serialized)
struct RateLimitTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        let app = try await Application.make(.testing)
        do {
            app.appDatabase = try AppDatabase(path: dbPath)   // inject before configure
            try await configure(app)
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            cleanup(dbPath)
            throw error
        }
        try await app.asyncShutdown()
        cleanup(dbPath)
    }

    private func cleanup(_ path: String) {
        for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    private func signIn(_ app: Application, _ token: String, _ name: String) async throws -> AuthResponse {
        var out: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/apple", beforeRequest: { req in
            try req.content.encode(AppleSignInRequest(identityToken: token, fullName: name))
        }, afterResponse: { res async throws in out = try res.content.decode(AuthResponse.self) })
        return try #require(out)
    }

    @Test("Invite codes carry 50 bits of entropy and normalize to one form")
    func inviteCodeShape() throws {
        let code = HouseholdStore.generateCode()
        // "BUDGET-XXXXX-XXXXX"
        #expect(code.hasPrefix("BUDGET-"))
        let normalized = HouseholdStore.normalizeCode(code)
        #expect(normalized == "BUDGET" + normalized.dropFirst(6))
        // 6 for "BUDGET" + 10 random characters, dashes stripped.
        #expect(normalized.count == 16)

        // However the partner types it, it resolves to the same stored value.
        #expect(HouseholdStore.normalizeCode(code.lowercased()) == normalized)
        #expect(HouseholdStore.normalizeCode(code.replacingOccurrences(of: "-", with: "")) == normalized)
        #expect(HouseholdStore.normalizeCode(" \(code) ") == normalized)

        // The alphabet deliberately excludes characters that are misread aloud.
        let random = normalized.dropFirst(6)
        #expect(!random.contains(where: { "O0I1".contains($0) }))

        // Distinct across many draws — catches a constant or a tiny keyspace.
        let many = Set((0..<500).map { _ in HouseholdStore.generateCode() })
        #expect(many.count == 500)
    }

    @Test("The limiter allows up to the limit, then reports a wait")
    func limiterCounts() async {
        let limiter = RateLimiter()
        let rule = RateLimiter.Rule(limit: 3, window: 60)
        let start = Date()

        for _ in 0..<3 {
            #expect(await limiter.consume(key: "k", rule: rule, now: start) == nil)
        }
        let blocked = await limiter.consume(key: "k", rule: rule, now: start)
        #expect(blocked != nil)

        // A different key has its own budget.
        #expect(await limiter.consume(key: "other", rule: rule, now: start) == nil)

        // The window rolls over and the budget comes back.
        let later = start.addingTimeInterval(61)
        #expect(await limiter.consume(key: "k", rule: rule, now: later) == nil)
    }

    @Test("Guessing invite codes gets throttled with 429")
    func joinIsRateLimited() async throws {
        try await withApp { app in
            let token = try await signIn(app, "dev:guesser", "Guesser").token

            var sawTooMany = false
            for _ in 0..<15 {
                try await app.testing().test(.POST, "v1/household/join", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(["code": "BUDGET-AAAAA-AAAAA",
                                            "memberDisplayName": "G"])
                }, afterResponse: { res async throws in
                    if res.status == .tooManyRequests {
                        sawTooMany = true
                        // Tells a well-behaved client when to come back.
                        #expect(res.headers.first(name: .retryAfter) != nil)
                    } else {
                        // Wrong code, but never a leak about which household.
                        #expect(res.status == .notFound)
                    }
                })
            }
            #expect(sawTooMany, "join should start refusing after the limit")
        }
    }
}
