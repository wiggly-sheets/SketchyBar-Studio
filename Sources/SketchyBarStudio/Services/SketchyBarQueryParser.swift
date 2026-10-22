import Foundation

/// The tolerant parser for `sketchybar --query` replies.
///
/// The reply is close to valid JSON but is not always valid JSON:
/// - Tab indent is legal JSON whitespace.
/// - "on" / "off" are quoted strings and parse fine.
/// - No trailing commas before closing braces.
/// - The real breakers are the backslash, which `escape_string` does not
///   escape, so a value holding a backslash emits an invalid escape.
/// - The error path returns "[!] …" and is not JSON at all.
struct SketchyBarQueryParser {
    /// Parses a --query reply into a dictionary, tolerating backslashes.
    ///
    /// The function replaces raw backslashes with escaped backslashes before
    /// parsing, so a value like "path\\to\\file" becomes valid JSON.
    static func parse(_ reply: String) throws -> [String: Any] {
        // Detect the error prefix first.
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[!]") {
            throw QueryError.errorReply(reply)
        }

        // Replace unescaped backslashes with escaped ones.
        let escaped = escapeBackslashes(reply)

        guard let data = escaped.data(using: .utf8) else {
            throw QueryError.encodingFailed
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw QueryError.notADictionary
        }
        return dict
    }

    /// Detects the "[!] …" error prefix and returns the error message.
    static func parseError(_ reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[!]") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces raw backslashes with escaped backslashes for JSON parsing.
    ///
    /// The daemon's escape_string only escapes " and \n. All other backslashes
    /// are emitted raw and become invalid JSON escapes (e.g., \t -> tab).
    /// We escape backslashes not followed by " or n (the only daemon escapes).
    private static func escapeBackslashes(_ string: String) -> String {
        // Replace \ that is NOT followed by " or n (daemon escapes).
        return string.replacingOccurrences(of: #"\\(?![\"n])"#, with: "\\\\", options: .regularExpression)
    }

    enum QueryError: LocalizedError {
        case errorReply(String)
        case notADictionary
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .errorReply(let reply):
                return "The query reply is an error: \(reply)"
            case .notADictionary:
                return "The query reply is not a dictionary"
            case .encodingFailed:
                return "The query reply could not be encoded as UTF-8"
            }
        }
    }
}