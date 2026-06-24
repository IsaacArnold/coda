import Foundation

/// Parse a multiline allowlist (one path per line): trim each line of surrounding
/// whitespace (incl. trailing \r from CRLF) and drop blank lines.
public func parseAllowlist(_ text: String) -> [String] {
    text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}
