import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

/// Serialized because each test points the server at its own temp SQLite file
/// via an env var read during `configure`.
@Suite("Auth & households", .serialized)
struct AuthHouseholdTests {

    /// Boots a fresh app against a throwaway database (dev auth on by default in
    /// the testing environment), runs the test, then tears down and deletes the
    /// database file.
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        setenv("BUDGET_DB_PATH", dbPath, 1)
        let app = try await Application.make(.testing)
        do {
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
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Signs in with a dev token and returns (session token, response).
    @discardableResult
    private func signIn(_ app: Application, token: String, name: String? = nil) async throws -> AuthResponse {
        var out: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/apple", beforeRequest: { req in
            try req.content.encode(AppleSignInRequest(identityToken: token, fullName: name))
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            out = try res.content.decode(AuthResponse.self)
        })
        return try #require(out)
    }

    private func bearer(_ token: String) -> HTTPHeaders {
        var h = HTTPHeaders()
        h.add(name: .authorization, value: "Bearer \(token)")
        return h
    }

    @Test("Sign in creates a user and returns a session token")
    func signInCreatesUser() async throws {
        try await withApp { app in
            let auth = try await signIn(app, token: "dev:alice", name: "Alice")
            #expect(auth.token.isEmpty == false)
            #expect(auth.user.displayName == "Alice")
            #expect(auth.household == nil)  // not onboarded yet
        }
    }

    @Test("Same Apple subject reuses the same user")
    func signInIsIdempotent() async throws {
        try await withApp { app in
            let first = try await signIn(app, token: "dev:alice", name: "Alice")
            let second = try await signIn(app, token: "dev:alice")
            #expect(first.user.id == second.user.id)
        }
    }

    @Test("/me requires a valid session")
    func meRequiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/me", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Create a household, invite, and partner joins — both see two members")
    func createInviteJoinFlow() async throws {
        try await withApp { app in
            // Alice signs in and creates a household.
            let alice = try await signIn(app, token: "dev:alice", name: "Alice")
            var created: MeResponse?
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { req in
                    try req.content.encode(CreateHouseholdRequest(name: "Our Home", memberDisplayName: "Alice"))
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    created = try res.content.decode(MeResponse.self)
                })
            let household = try #require(created?.household)
            #expect(created?.members.count == 1)
            #expect(created?.member?.role == .owner)

            // Alice generates an invite code.
            var invite: InviteResponse?
            try await app.testing().test(.POST, "v1/household/invite", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    invite = try res.content.decode(InviteResponse.self)
                })
            let code = try #require(invite?.code)
            #expect(code.hasPrefix("BUDGET-"))

            // Bob signs in and joins with the code.
            let bob = try await signIn(app, token: "dev:bob", name: "Bob")
            var joined: MeResponse?
            try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
                beforeRequest: { req in
                    try req.content.encode(JoinHouseholdRequest(code: code, memberDisplayName: "Bob"))
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    joined = try res.content.decode(MeResponse.self)
                })
            #expect(joined?.household?.id == household.id)
            #expect(joined?.members.count == 2)
            #expect(joined?.member?.role == .member)

            // Alice now sees both members too.
            try await app.testing().test(.GET, "v1/household", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    let me = try res.content.decode(MeResponse.self)
                    #expect(me.members.count == 2)
                })
        }
    }

    @Test("A bad invite code is rejected")
    func joinWithBadCodeFails() async throws {
        try await withApp { app in
            let bob = try await signIn(app, token: "dev:bob", name: "Bob")
            try await app.testing().test(.POST, "v1/household/join", headers: bearer(bob.token),
                beforeRequest: { req in
                    try req.content.encode(JoinHouseholdRequest(code: "BUDGET-NOPE99", memberDisplayName: "Bob"))
                }, afterResponse: { res async in
                    #expect(res.status == .notFound)
                })
        }
    }
}
