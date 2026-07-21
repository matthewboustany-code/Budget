import Foundation

extension String {
    /// Nil when the string is empty (after the caller has trimmed, if needed).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
