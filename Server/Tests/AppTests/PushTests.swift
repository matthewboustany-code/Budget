import Testing
import Foundation
import Vapor
import VaporTesting
import BudgetModels
@testable import App

/// Bill-reminder push: device registration, and the digest wording that gets
/// sent. Actual APNs delivery isn't exercised — that needs Apple.
@Suite("Bill reminder push", .serialized)
struct PushTests {

    /// Same harness as the other suites: inject the database before
    /// `configure` so no test touches process environment variables.
    private func withApp(_ test: (Application, String, UUID) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-push-\(UUID().uuidString).sqlite"
        let app = try await Application.make(.testing)
        do {
            app.appDatabase = try AppDatabase(path: dbPath)
            try await configure(app)
            var auth: AuthResponse?
            try await app.testing().test(.POST, "v1/auth/apple", beforeRequest: { req in
                try req.content.encode(AppleSignInRequest(identityToken: "dev:alice", fullName: "Alice"))
            }, afterResponse: { res async throws in
                auth = try res.content.decode(AuthResponse.self)
            })
            let session = try #require(auth)
            try await test(app, session.token, session.user.id)
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

    // MARK: - Digest wording

    @Test("A single due bill reads in the singular")
    func singleBill() {
        let bills = [TestBills.make(name: "Rent", status: .upcoming)]
        #expect(BillReminderCommand.title(for: bills) == "1 bill due soon")
        #expect(BillReminderCommand.body(for: bills) == "Rent")
    }

    @Test("An all-overdue set is titled as overdue, not merely due")
    func overdueTitle() {
        let bills = [TestBills.make(name: "Rent", status: .overdue),
                     TestBills.make(name: "Power", status: .overdue)]
        #expect(BillReminderCommand.title(for: bills) == "2 bills overdue")
    }

    @Test("A mixed set falls back to the neutral due-soon title")
    func mixedTitle() {
        let bills = [TestBills.make(name: "Rent", status: .overdue),
                     TestBills.make(name: "Power", status: .upcoming)]
        #expect(BillReminderCommand.title(for: bills) == "2 bills due soon")
    }

    @Test("The body names at most three bills, then counts the rest")
    func bodyTruncates() {
        let bills = ["Rent", "Power", "Water", "Internet", "Phone"]
            .map { TestBills.make(name: $0, status: .upcoming) }
        #expect(BillReminderCommand.body(for: bills) == "Rent, Power, Water and 2 more")
    }

    // MARK: - Registration

    @Test("Registering the same device twice leaves one row, not two")
    func registrationIsIdempotent() async throws {
        try await withApp { app, token, userID in
            for _ in 0..<2 {
                try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                    try req.content.encode(RegisterDeviceRequest(token: "abc123", environment: "sandbox"))
                }, afterResponse: { res async in
                    #expect(res.status == .noContent)
                })
            }
            let stored = try await DeviceTokenStore(db: app.appDatabase.dbPool)
                .tokens(userIDs: [userID])
            #expect(stored.count == 1)
            #expect(stored.first?.environment == "sandbox")
        }
    }

    @Test("A non-hex token is refused rather than stored and retried forever")
    func rejectsMalformedToken() async throws {
        try await withApp { app, token, _ in
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(RegisterDeviceRequest(token: "not a token!", environment: "sandbox"))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("An unknown environment string is coerced to sandbox, never trusted raw")
    func coercesEnvironment() async throws {
        try await withApp { app, token, userID in
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(RegisterDeviceRequest(token: "beef", environment: "nonsense"))
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            let stored = try await DeviceTokenStore(db: app.appDatabase.dbPool)
                .tokens(userIDs: [userID])
            #expect(stored.first?.environment == "sandbox")
        }
    }

    @Test("Registration requires a session")
    func requiresAuth() async throws {
        try await withApp { app, _, _ in
            try await app.testing().test(.POST, "v1/devices", beforeRequest: { req in
                try req.content.encode(RegisterDeviceRequest(token: "abc123", environment: "sandbox"))
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Signing out removes the token")
    func unregister() async throws {
        try await withApp { app, token, userID in
            let store = DeviceTokenStore(db: app.appDatabase.dbPool)
            try await store.register(token: "abc123", userID: userID, environment: "sandbox")
            try await app.testing().test(.DELETE, "v1/devices/abc123", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            #expect(try await store.tokens(userIDs: [userID]).isEmpty)
        }
    }

    @Test("Push stays off unless every credential is present")
    func partialCredentialsDoNotEnablePush() {
        var config = AppConfig(appleBundleID: "x", sessionJWTSecret: "s",
                               plaidClientID: "", plaidSecret: "", plaidEnv: "sandbox",
                               plaidProducts: [], plaidWebhookURL: nil,
                               plaidTokenEncKey: "k", authDevMode: true)
        #expect(!config.apnsConfigured)
        config.apnsKeyID = "K"
        config.apnsTeamID = "T"
        config.apnsTopic = "com.mbandhb.budget"
        #expect(!config.apnsConfigured)   // no key material yet
        config.apnsKeyP8 = "-----BEGIN PRIVATE KEY-----"
        #expect(config.apnsConfigured)
    }
}

private enum TestBills {
    static func make(name: String, status: BillStatus) -> Bill {
        Bill(id: UUID(), householdID: UUID(), recurringSeriesID: UUID(), name: name,
             amount: 10, dueDate: Date(), status: status)
    }
}
