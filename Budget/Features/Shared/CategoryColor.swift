import SwiftUI
import BudgetModels

/// Category colors: the palette the editor offers, the hex bridge, and the
/// deterministic fallback for categories nobody has colored yet.
///
/// `colorHex` has been on `BudgetCategory` since P3 and was never rendered
/// (v1.1 §5.3). It now drives the budget bars and the spending chart.
enum CategoryPalette {
    /// Twelve hues, evenly spread and distinguishable in both light and dark.
    /// Fixed and ordered: the fallback indexes into it, so inserting a colour
    /// in the middle would silently re-color every unset category.
    static let swatches: [String] = [
        "#EF4444", "#F97316", "#F59E0B", "#EAB308",
        "#84CC16", "#22C55E", "#14B8A6", "#06B6D4",
        "#3B82F6", "#6366F1", "#A855F7", "#EC4899",
    ]

    /// The color to draw a category in: its own if set, otherwise a stable one
    /// picked from its id. A chart whose bars are all the accent color says
    /// nothing, and asking someone to hand-color twenty seeded categories
    /// before their first useful chart is a bad trade.
    static func color(for category: BudgetCategory?) -> Color {
        if let hex = category?.colorHex, let color = Color(hex: hex) { return color }
        guard let id = category?.id else { return .secondary }
        return Color(hex: fallbackHex(for: id)) ?? .accentColor
    }

    /// Derived from the UUID's bytes, so the same category is the same color on
    /// both partners' phones without the server storing anything.
    static func fallbackHex(for id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { ($0 &+ Int($1) &* 31) % swatches.count }
        return swatches[abs(sum) % swatches.count]
    }
}

extension Color {
    /// `#RRGGBB` (with or without the hash). Returns nil rather than a silent
    /// black so a bad value falls back to the palette instead of vanishing
    /// against a dark background.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension CategoryStore {
    /// Color for a category id, for callers that only have the id (charts,
    /// transaction rows).
    func color(for id: UUID?) -> Color {
        CategoryPalette.color(for: id.flatMap { byID[$0] })
    }
}
