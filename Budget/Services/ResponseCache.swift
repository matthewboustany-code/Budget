import Foundation
import CryptoKit

/// The last successfully decoded JSON for each GET, on disk in Application
/// Support. Stores read it synchronously at init so a tab's first frame shows
/// the last-known data instead of a blank list, then refresh from the network.
/// It also keeps an offline launch (see `HouseholdStore.isOffline`) useful.
///
/// Keyed by path + query and scoped to one signed-in session: `clear()` runs
/// on sign-out, and changing the server URL signs out. The directory is
/// injectable so a widget extension can later share it via an App Group.
@MainActor
final class ResponseCache {
    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ResponseCache", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: url(for: key))
    }

    func store(_ data: Data, for key: String) {
        try? data.write(to: url(for: key), options: .atomic)
    }

    /// Drops everything — the next user must never see the previous one's data.
    func clear() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A stable key for a GET. Query order is kept as given: callers build
    /// the same request the same way, and reordering would only add misses.
    static func key(path: String, query: [URLQueryItem]) -> String {
        guard !query.isEmpty else { return path }
        return path + "?" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    private func url(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".json")
    }
}
