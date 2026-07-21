import Foundation
import BudgetModels

/// Central async/await HTTP client for the Budget backend. Every request is
/// authenticated, so a single client owns bearer-token injection, ISO8601
/// coding, and error decoding. Runs on the main actor (the project's default
/// isolation); the actual network I/O is `async` and suspends, so it never
/// blocks the UI.
@MainActor
final class APIClient {
    private let session: URLSession
    private let baseURL: URL
    private let tokenProvider: () -> String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(baseURL: URL = ServerConfig.baseURL,
         session: URLSession = .shared,
         tokenProvider: @escaping () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Verbs

    func get<Response: Decodable>(_ path: String,
                                  query: [URLQueryItem] = []) async throws -> Response {
        try await send(path, method: "GET", query: query, body: Optional<Empty>.none)
    }

    @discardableResult
    func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        try await send(path, method: "POST", body: body)
    }

    @discardableResult
    func patch<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        try await send(path, method: "PATCH", body: body)
    }

    @discardableResult
    func put<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        try await send(path, method: "PUT", body: body)
    }

    func delete(_ path: String) async throws {
        let _: Empty = try await send(path, method: "DELETE", body: Optional<Empty>.none)
    }

    // MARK: - Core

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String, method: String,
        query: [URLQueryItem] = [],
        body: Body?) async throws -> Response {

        // Join base URL + path predictably (paths carry their own "v1/" prefix).
        var base = baseURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(string: base + "/" + trimmedPath) else {
            throw APIClientError.transport("Bad URL for path \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw APIClientError.transport("Bad URL components for path \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body, !(body is Empty) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw APIClientError.server(status: http.statusCode, reason: apiError.reason)
            }
            throw APIClientError.server(status: http.statusCode,
                                        reason: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }

        if Response.self == Empty.self { return Empty() as! Response }
        if data.isEmpty { throw APIClientError.decoding("Empty response body") }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIClientError.decoding(String(describing: error))
        }
    }
}

/// Placeholder for request/response bodies that carry no JSON.
struct Empty: Codable {
    init() {}
}

enum APIClientError: Error, LocalizedError {
    case transport(String)
    case server(status: Int, reason: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .transport(let m): return "Network error: \(m)"
        case .server(let status, let reason): return "Server error \(status): \(reason)"
        case .decoding(let m): return "Could not read the server's response: \(m)"
        }
    }

    /// True when the failure is an expired/invalid session (drives sign-out).
    var isUnauthorized: Bool {
        if case .server(let status, _) = self { return status == 401 }
        return false
    }
}
