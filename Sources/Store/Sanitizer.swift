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
}

/// The single sanitizer/extractor (spec §3.5). Mail content is hostile input:
/// nothing from a message reaches the terminal or the index except through
/// this type. Bump `version` on behavior change so stored bodies re-derive.
public enum Sanitizer {
    public static let version = 1

    /// Builds the derived body. Prefers the sender's text/plain part; falls
    /// back to stripping the HTML. Also inventories cid: and remote references
    /// so the future WKWebView renderer can block remote loads (spec §3.5).
    public static func sanitize(html: Data?, plainText: String?) -> SanitizedBody {
        let htmlString = html.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let text: String
        if let plainText, !plainText.isEmpty {
            text = plainText
        } else {
            text = strippedText(fromHTML: htmlString)
        }
        return SanitizedBody(
            rawHTML: html,
            plainText: text,
            sanitizerVersion: version,
            cidReferences: matches(#"src="cid:([^"]+)""#, in: htmlString),
            remoteURLs: matches(#"(?:src|href)="(https?://[^"]+)""#, in: htmlString))
    }

    /// Strips C0/C1 control characters (keeping \n and \t) and ANSI CSI/OSC
    /// escape sequences. Every message-derived string printed to a terminal
    /// goes through this — escape injection is reachable from `hudson list`.
    public static func terminalSafe(_ string: String) -> String {
        // Drop CSI/OSC sequences first (ESC or 0x9B introducer), then any
        // remaining control scalars.
        var cleaned = string
        for pattern in [
            #"(?:\x1B\[|\x{9B})[0-?]*[ -/]*[@-~]"#,     // CSI … final byte
            #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)?"#,     // OSC … BEL/ST
            #"\x1B."#,                                   // any other escape pair
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return String(cleaned.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
        })
    }

    // MARK: - HTML text extraction (M2: tag stripper; real rendering is WKWebView later)

    static func strippedText(fromHTML html: String) -> String {
        var text = html
        // Drop script/style bodies entirely, then all tags, then decode the
        // entities that matter for readability.
        for pattern in [#"(?is)<(script|style)\b.*?</\1>"#, #"(?s)<br\s*/?>"#] {
            text = text.replacingOccurrences(
                of: pattern, with: pattern.contains("br") ? "\n" : " ",
                options: .regularExpression)
        }
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, plain) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
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
        return regex.matches(in: string, range: range).compactMap { match in
            Range(match.range(at: 1), in: string).map { String(string[$0]) }
        }
    }
}
