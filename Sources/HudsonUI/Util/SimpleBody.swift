import Foundation

/// Decides whether a message body can be re-rendered in Hudson's OWN
/// typography on the app's dark ground, instead of being handed to the
/// white-carded `WKWebView`.
///
/// The question this answers is deliberately not "will the sender's colors
/// survive a dark background?" — the native path discards sender styling
/// wholesale, so colors can never break it. The question is whether the
/// message's MEANING survives having all styling stripped. A prose reply's
/// meaning is in its words, so it does. A newsletter's meaning lives in its
/// layout, images, and brand color, so it doesn't — that one keeps the card.
///
/// The test is an ALLOWLIST, and that direction is the whole point: an
/// unrecognized tag routes to the card, which is simply today's behavior. A
/// blocklist would fail the other way — the first newsletter using a tag
/// nobody anticipated would render as garbage. Here the worst case is a white
/// card, never unreadable text.
enum SimpleBody {
    /// Tags whose content is prose and whose meaning survives losing every
    /// attribute. `<style>`, `<table>`, and everything else are absent ON
    /// PURPOSE — their absence is what routes a message to the card.
    ///
    /// `img` IS listed, but is not thereby waved through: every `<img>` is
    /// additionally checked by `containsContentImage`, so a real picture still
    /// routes to the card and only a contentless tracking pixel passes.
    ///
    /// `font` is here even though it exists only to carry `color`/`face`: the
    /// attributes get dropped, and what's left is prose. Older Outlook and
    /// Apple Mail wrap ordinary replies in it constantly.
    static let allowedTags: Set<String> = [
        // Document scaffolding — Gmail and Outlook both send whole documents.
        "html", "head", "body", "meta", "title", "base",
        // Blocks
        "p", "div", "br", "hr", "blockquote", "pre", "center",
        "h1", "h2", "h3", "h4", "h5", "h6",
        // Lists
        "ul", "ol", "li", "dl", "dt", "dd",
        // Inline
        "a", "span", "b", "strong", "i", "em", "u", "s", "strike", "del", "ins",
        "code", "tt", "kbd", "samp", "var", "small", "big", "sub", "sup",
        "font", "abbr", "cite", "q", "mark", "wbr", "nobr", "o:p",
        // Gated by `containsContentImage`, not admitted outright.
        "img",
    ]

    /// Tags that build a page rather than say anything — admitted only under
    /// the short-document rule in `isSimple`, never on their own.
    ///
    /// These are what a mailing platform wraps around a message: nested
    /// layout tables, a stylesheet, Word's `<xml>` island, a `<head>`. A
    /// one-line reply sent through a sales tool arrives inside twenty-six
    /// table cells, none of which mean anything.
    static let wrapperTags: Set<String> = [
        "table", "tbody", "thead", "tfoot", "tr", "td", "th", "colgroup", "col",
        "style", "xml", "noscript", "o:wordDocument", "st1:place", "v:shape",
    ]

    /// How much visible text a wrapper-laden document may hold and still be
    /// treated as prose.
    ///
    /// The reasoning is that layout cannot be load-bearing when there is
    /// little to lay out: a table around a couple of paragraphs is packaging.
    ///
    /// This is a BACKSTOP, not the primary defence — `containsContentImage`
    /// does most of the work, and a real newsletter is disqualified by its
    /// pictures long before its length is consulted. So the bound is set
    /// generously, from measurements against a real mailbox: mailer-wrapped
    /// replies there run 1.9k–2.6k characters (the extracted text includes
    /// quoted history and hidden preheader copy, so it far exceeds what the
    /// reader sees), while image-bearing newsletters run about 137k. An
    /// earlier, tighter 1200 looked reasonable in the abstract and failed
    /// against every real message it was meant to fix.
    ///
    /// What this does cost: an image-free document whose meaning genuinely
    /// lives in a table — a no-logo receipt with line items — renders as
    /// unstyled lines. Rare enough, and legible when it happens.
    static let maxWrappedTextLength = 8_000

    /// True when every tag in `html` is prose-safe. Empty input is trivially
    /// simple (no tags to disqualify it).
    ///
    /// Tags inside HTML comments are deliberately NOT skipped. Newsletters
    /// hide their layout in `<!--[if mso]>` conditional blocks, and scanning
    /// into comments means those `<table>`s still disqualify the message —
    /// the conservative direction. Stripping comments first would let exactly
    /// those newsletters slip onto the native path.
    /// `visibleTextLength` is the length of the sanitizer's own extracted
    /// plain text for this message — passed in rather than re-derived here, so
    /// there is one definition of "the visible text" in the app.
    ///
    /// It defaults to `.max`, i.e. "assume long", because an unknown length
    /// must fail toward the card: a caller that can't say how much text a
    /// document holds has given us no grounds to decide its tables are
    /// decorative. The default is irrelevant to pure-prose documents, which
    /// are simple at any length.
    static func isSimple(html: String, visibleTextLength: Int = .max) -> Bool {
        guard let regex = tagNameRegex else { return false }
        if containsContentImage(html) { return false }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var usesWrappers = false
        for match in matches {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            if allowedTags.contains(name) { continue }
            guard wrapperTags.contains(name) else { return false }
            usesWrappers = true
        }
        // Pure prose: simple at any length. Wrapped prose: only while short
        // enough that the wrapping cannot be carrying the meaning.
        return usesWrappers ? visibleTextLength <= maxWrappedTextLength : true
    }

    /// Whether the document carries an image that actually says something.
    ///
    /// A 1×1 hidden tracking pixel is not content: it conveys nothing to the
    /// reader, and the native path simply never renders it — which also means
    /// its URL is never fetched, so routing this way is a privacy improvement
    /// over the card, where it sat behind "Load remote images".
    ///
    /// This distinction is load-bearing rather than fussy. Essentially every
    /// message sent through a mailing platform or a sales tool carries a
    /// pixel, so disqualifying on the mere presence of `<img>` sent the great
    /// majority of ordinary prose mail to the white card.
    ///
    /// An `<img>` with no size information at all counts as content — the
    /// conservative direction, since guessing wrong the other way would
    /// silently delete a picture from the message.
    static func containsContentImage(_ html: String) -> Bool {
        guard let regex = imgTagRegex else { return true }  // can't tell -> assume content
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        return matches.contains { !isTrackingPixel(ns.substring(with: $0.range)) }
    }

    /// A contentless image: explicitly hidden, or measuring a few pixels or
    /// fewer in either dimension.
    static func isTrackingPixel(_ imgTag: String) -> Bool {
        let tag = imgTag.lowercased().replacingOccurrences(of: " ", with: "")
        if tag.contains("display:none") || tag.contains("visibility:hidden") { return true }
        for dimension in ["width", "height"] {
            if let value = measurement(of: dimension, in: tag), value <= 3 { return true }
        }
        return false
    }

    /// The `width`/`height` of an img tag, from either the HTML attribute
    /// (`width="1"`) or the inline style (`width:1px`). Whitespace is already
    /// squeezed out by the caller, so one pattern covers both spellings.
    private static func measurement(of name: String, in tag: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "\(name)[:=][\"']?(\\d+)") else {
            return nil
        }
        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return Int(ns.substring(with: match.range(at: 1)))
    }

    private static let imgTagRegex = try? NSRegularExpression(pattern: "(?is)<img\\b[^>]*>")

    /// Matches the tag NAME of any opening or closing tag. `<!--`, `<!DOCTYPE`,
    /// and a bare `<` in prose ("a < b") never match, since `!`, `-`, and a
    /// space aren't in the leading character class — so none of them can
    /// masquerade as an unknown tag and force a message onto the card.
    /// `o:p` (Word's namespaced paragraph) is why ":" is in the name class.
    private static let tagNameRegex = try? NSRegularExpression(
        pattern: "</?([a-zA-Z][a-zA-Z0-9:_-]*)")
}
