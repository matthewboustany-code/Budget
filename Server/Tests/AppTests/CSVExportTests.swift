import Testing
import Foundation
import VaporTesting
import BudgetModels
@testable import App

@Suite("CSV export", .serialized)
struct CSVExportTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let dbPath = NSTemporaryDirectory() + "budget-test-\(UUID().uuidString).sqlite"
        let app = try await Application.make(.testing)
        do {
            app.appDatabase = try AppDatabase(path: dbPath)   // inject before configure
            try await configure(app)
            app.plaidTransport = MockPlaidTransport()
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

    private func bearer(_ token: String) -> HTTPHeaders {
        var h = HTTPHeaders(); h.add(name: .authorization, value: "Bearer \(token)"); return h
    }

    private func signIn(_ app: Application, _ token: String, _ name: String) async throws -> AuthResponse {
        var out: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/apple", beforeRequest: { req in
            try req.content.encode(AppleSignInRequest(identityToken: token, fullName: name))
        }, afterResponse: { res async throws in out = try res.content.decode(AuthResponse.self) })
        return try #require(out)
    }

    // MARK: - Encoding (pure)

    @Test("Fields are quoted per RFC 4180 and quotes are doubled")
    func quoting() {
        #expect(CSVWriter.field("plain") == "plain")
        #expect(CSVWriter.field("has,comma") == "\"has,comma\"")
        #expect(CSVWriter.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVWriter.field("two\nlines") == "\"two\nlines\"")
    }

    @Test("Rows are CRLF-terminated and carry a BOM for Excel")
    func rowsAndBOM() {
        let csv = CSVWriter.encode([["a", "b"], ["1", "2"]])
        #expect(csv == "\u{FEFF}a,b\r\n1,2\r\n")
        #expect(CSVWriter.encode([["a"]], includeBOM: false) == "a\r\n")
    }

    /// A merchant name is attacker-controlled data arriving from the bank. A
    /// payee called `=cmd|...` must never execute when the file is opened.
    @Test("Formula-leading text is defused, but negative numbers survive")
    func formulaInjection() {
        #expect(CSVWriter.escapeFormula("=1+1") == "'=1+1")
        #expect(CSVWriter.escapeFormula("@SUM(A1)") == "'@SUM(A1)")
        #expect(CSVWriter.escapeFormula("+31 555") == "'+31 555")
        #expect(CSVWriter.escapeFormula("-12.34") == "-12.34")   // an amount
        #expect(CSVWriter.escapeFormula("-cmd") == "'-cmd")      // not a number
    }

    // MARK: - Route

    @Test("Export returns visible rows as an attachment, honouring from/to")
    func exportRoute() async throws {
        try await withApp { app in
            let alice = try await signIn(app, "dev:alice", "Alice")
            try await app.testing().test(.POST, "v1/household", headers: bearer(alice.token),
                beforeRequest: { try $0.content.encode(CreateHouseholdRequest(name: "H", memberDisplayName: "Alice")) },
                afterResponse: { _ async in })
            var account: Account?
            try await app.testing().test(.POST, "v1/accounts", headers: bearer(alice.token),
                beforeRequest: {
                    try $0.content.encode(CreateManualAccountRequest(name: "Cash", type: .checking,
                                                               visibility: .shared, currentBalance: 100))
                },
                afterResponse: { res async throws in account = try res.content.decode(Account.self) })
            let cash = try #require(account)

            let iso = ISO8601DateFormatter()
            let old = try #require(iso.date(from: "2026-01-15T12:00:00Z"))
            let recent = try #require(iso.date(from: "2026-08-15T12:00:00Z"))
            for (date, name) in [(old, "Old Charge"), (recent, "=DANGER, Inc")] {
                try await app.testing().test(.POST, "v1/transactions", headers: bearer(alice.token),
                    beforeRequest: {
                        try $0.content.encode(CreateTransactionRequest(
                            accountID: cash.id, amount: 25, date: date, name: name))
                    },
                    afterResponse: { res async in #expect(res.status == .ok) })
            }

            // Unbounded: both rows, newest first, with the header.
            try await app.testing().test(.GET, "v1/transactions/export.csv", headers: bearer(alice.token),
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentDisposition?.value == .attachment)
                    let body = res.body.string
                    #expect(body.hasPrefix("\u{FEFF}Date,Description"))
                    let lines = body.split(separator: "\r\n")
                    #expect(lines.count == 3)
                    #expect(lines[1].contains("2026-08-15"))
                    #expect(lines[2].contains("2026-01-15"))
                    // The injection attempt is neutralised *and* quoted (comma).
                    #expect(body.contains("\"'=DANGER, Inc\""))
                })

            // Bounded: the January row falls outside the window.
            try await app.testing().test(.GET, "v1/transactions/export.csv?from=2026-06-01T00:00:00Z",
                headers: bearer(alice.token),
                afterResponse: { res async throws in
                    let lines = res.body.string.split(separator: "\r\n")
                    #expect(lines.count == 2)
                    #expect(!res.body.string.contains("Old Charge"))
                })
        }
    }

    @Test("Export is behind auth")
    func exportRequiresAuth() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/transactions/export.csv",
                afterResponse: { res async in #expect(res.status == .unauthorized) })
        }
    }
}
