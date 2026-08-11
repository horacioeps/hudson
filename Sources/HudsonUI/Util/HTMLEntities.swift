import Foundation

/// Decodes the HTML entities Gmail leaves in its plain-text `snippet` field
/// (e.g. `I&#39;m` → `I'm`, `Let&amp;#39;s` stays safe) so the strings Hudson
/// renders as plain SwiftUI `Text` — collapsed thread previews, inbox rows,
/// search hits — read naturally instead of showing raw `&#39;`/`&amp;` markup.
///
/// The reading pane's HTML *body* never needs this: `WKWebView` decodes
/// entities itself. This is ONLY for snippet strings shown outside the web
/// view. Total and never-throwing — snippets are sender-controlled, so
/// malformed entities are left verbatim rather than crashing.
enum HTMLEntities {
    /// Decodes the entities that actually show up in Gmail snippets. Numeric
    /// entities (`&#39;`, `&#x27;`) are handled first, then the common named
    /// ones with `&amp;` LAST — so a double-encoded `&amp;#39;` decodes only its
    /// outer `&amp;` to `&#39;` and stops, never all the way to `'` (the same
    /// "amp last" guard `Store/Sanitizer` uses).
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }  // fast path: nothing to decode
        var result = decodeNumericEntities(text)
        for (entity, plain) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&amp;", "&"),
        ] {
            result = result.replacingOccurrences(of: entity, with: plain)
        }
        return result
    }

    /// Replaces `&#NN;` (decimal) and `&#xHH;` (hex) numeric character
    /// references with their Unicode scalar. A malformed or out-of-range
    /// reference is left exactly as written.
    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#"),
            let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);")
        else { return text }
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                output += String(scalar)
            } else {
                output += ns.substring(with: match.range)  // leave malformed as-is
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}
