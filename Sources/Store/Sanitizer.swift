import Foundation

/// Derived, display-safe content for one message body (spec §3.5). The raw
/// HTML is carried as opaque bytes for the future renderer; everything the
/// terminal or FTS ever sees comes from `plainText`.
public struct SanitizedBody: Sendable, Equatable {
    public let rawHTML: Data?
    public let plainText: String
    public let sanitizerVersion: Int
    public let cidReferences: [String]
    public let remoteURLs: [String]
    // No public initializer by design (spec §3.5): a `SanitizedBody` is only
    // ever the OUTPUT of `Sanitizer.sanitize`, so untrusted content can never
    // reach the terminal or FTS index without passing through the sanitizer.
    // The implicit memberwise init stays `internal` — usable inside Store,
    // never fabricable from another module.
}

/// The single sanitizer/extractor (spec §3.5). Mail content is hostile input:
/// nothing from a message reaches the terminal or the index except through
/// this type. Bump `version` on behavior change so stored bodies re-derive.
public enum Sanitizer {
    public static let version = 1

    /// Builds the derived body. Prefers the sender's text/plain part; falls
    /// back to stripping the HTML. Also inventories cid: and remote references
    /// so the future WKWebView renderer can block remote loads (spec §3.5).
    /// Uses lossy UTF-8 decode (U+FFFD for invalid bytes) to prevent evasion
    /// via malformed input. Collects all matches, then dedupes, then caps at 200
    /// per category to prevent padding-based evasion attacks.
    public static func sanitize(html: Data?, plainText: String?) -> SanitizedBody {
        let htmlString = html.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let text: String
        if let plainText, !plainText.isEmpty {
            text = plainText
        } else {
            text = strippedText(fromHTML: htmlString)
        }
        // Collect all matches (no early cap), then dedupe, then cap at 200
        let cidMatches = matches(#"(?i)src\s*=\s*["']?cid:([^"'\s>]+)"#, in: htmlString)
        let remoteMatches1 = matches(#"(?i)(?:src|href)\s*=\s*["']?(https?://[^"'\s>]+)"#, in: htmlString)
        let remoteMatches2 = matches(#"(?i)url\(\s*["']?(https?://[^"')\s]+)"#, in: htmlString)

        return SanitizedBody(
            rawHTML: html,
            plainText: text,
            sanitizerVersion: version,
            cidReferences: Array(deduped(cidMatches).prefix(200)),
            remoteURLs: Array(deduped(remoteMatches1 + remoteMatches2).prefix(200)))
    }

    /// Strips C0/C1 control characters (keeping \n and \t), ANSI CSI/OSC
    /// escape sequences, bidirectional marks, and zero-width characters.
    /// Every message-derived string printed to a terminal goes through this —
    /// escape injection is reachable from `hudson list`. When `singleLine`
    /// is true, also replaces \n and \t with spaces (list-style renderers).
    public static func terminalSafe(_ string: String, singleLine: Bool = false) -> String {
        // Drop CSI/OSC sequences first (ESC or 0x9B introducer), then any
        // remaining control scalars, bidi marks, and zero-width characters.
        var cleaned = string
        for pattern in [
            #"(?:\x1B\[|\x{9B})[0-?]*[ -/]*[@-~]"#,     // CSI … final byte
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?"#,     // OSC … BEL/ST
            #"\x1B."#,                                   // any other escape pair
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        let result = String(cleaned.unicodeScalars.filter { scalar in
            let val = scalar.value
            // Keep newline and tab always; conditional replacement happens after
            if scalar == "\n" || scalar == "\t" { return true }
            // Reject C0 (0x00–0x1F), C1 (0x7F–0x9F)
            if val < 0x20 || (0x7F...0x9F).contains(val) { return false }
            // Reject bidi marks (U+200B–U+200F, U+202A–U+202E, U+2066–U+2069, U+2028, U+2029)
            if (0x200B...0x200F).contains(val) || (0x202A...0x202E).contains(val)
                || (0x2066...0x2069).contains(val) || val == 0x2028 || val == 0x2029 {
                return false
            }
            return true
        })
        return singleLine ? result.replacingOccurrences(of: #"[\n\t]"#, with: " ", options: .regularExpression) : result
    }

    // MARK: - HTML text extraction (M2: tag stripper; real rendering is WKWebView later)

    static func strippedText(fromHTML html: String) -> String {
        var text = html
        // Drop script/style bodies entirely (both terminated and unterminated),
        // then all tags, then decode entities (amp last to prevent double-decode).
        for pattern in [#"(?is)<(script|style)\b.*?</\1>"#, #"(?is)<(script|style)\b[^>]*>.*"#, #"(?s)<br\s*/?>"#] {
            text = text.replacingOccurrences(
                of: pattern, with: pattern.contains("br") ? "\n" : " ",
                options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        // Decode entities with &amp; last to prevent re-encoding attacks
        for (entity, plain) in [
            ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ pattern: String, in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(string.startIndex..., in: string)
        var results: [String] = []
        for match in regex.matches(in: string, range: range) {
            if let range = Range(match.range(at: 1), in: string) {
                let captured = String(string[range])
                // Keep full value if under cap; drop over-long entries to avoid partial URLs
                if captured.count <= 2048 {
                    results.append(captured)
                }
            }
        }
        return results
    }

    static func deduped(_ array: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in array {
            if !seen.contains(item) {
                seen.insert(item)
                result.append(item)
            }
        }
        return result
    }
}
