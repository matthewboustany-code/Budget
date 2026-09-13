import Foundation

/// RFC 4180 CSV encoding, with two accommodations the spec doesn't cover:
/// Excel needs a UTF-8 BOM to read non-ASCII merchant names correctly, and
/// spreadsheet formula injection has to be defused (see `escapeFormula`).
enum CSVWriter {

    /// Characters that make a spreadsheet treat a cell as a formula. Plaid
    /// merchant names come from the outside world, so a payee literally named
    /// `=cmd|...` would execute on open in Excel/Sheets. Prefixing with a
    /// single quote renders the text verbatim and neutralises it.
    private static let formulaLeaders: Set<Character> = ["=", "+", "-", "@"]

    /// `rows` is the header row followed by the data rows.
    static func encode(_ rows: [[String]], includeBOM: Bool = true) -> String {
        // CRLF line endings: RFC 4180 requires them, and Excel on Windows
        // mis-renders a lone LF in quoted fields.
        let body = rows.map { row in
            row.map(field).joined(separator: ",")
        }.joined(separator: "\r\n")
        let terminated = body.isEmpty ? "" : body + "\r\n"
        return includeBOM ? "\u{FEFF}" + terminated : terminated
    }

    /// Quote when the value contains a delimiter, a quote, or a newline;
    /// doubling any embedded quotes.
    static func field(_ raw: String) -> String {
        let value = escapeFormula(raw)
        let needsQuoting = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A leading formula character is prefixed with `'`. A bare negative
    /// number (`-12.34`) is left alone — it is a value, not a formula, and
    /// mangling it would break every amount column in the file.
    ///
    /// The digit check is deliberately hand-rolled: `Decimal(string:)` parses
    /// the leading valid portion and so accepts `"-cmd"`, which would let an
    /// injection through.
    static func escapeFormula(_ raw: String) -> String {
        guard let first = raw.first, formulaLeaders.contains(first) else { return raw }
        if first == "-", isPlainNumber(raw.dropFirst()) { return raw }
        return "'" + raw
    }

    private static func isPlainNumber(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.contains(where: \.isNumber) else { return false }
        return text.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
    }
}
