import Foundation

/// One run of body text sharing the same inline styling. Deliberately carries
/// SEMANTICS (bold, a link) rather than presentation (a font, a color): the
/// whole point of the native render path is that Hudson picks the type, so a
/// span must not be able to express a sender's font or color at all.
struct BodySpan: Equatable, Sendable {
    var text: String
    var bold = false
    var italic = false
    var underline = false
    var monospace = false
    var link: URL?

    /// Everything except `text` — the key spans merge on.
    fileprivate var styleKey: BodySpan {
        BodySpan(
            text: "", bold: bold, italic: italic, underline: underline,
            monospace: monospace, link: link)
    }
}

/// A message body split into the reply the sender actually wrote and the
/// thread history quoted underneath it. `quoted` is empty when there's no
/// history to hide.
struct ParsedBody: Equatable, Sendable {
    var new: [BodySpan] = []
    var quoted: [BodySpan] = []

    /// The concatenated text of a span list — for tests and for the
    /// "is there anything here?" checks the view makes.
    static func text(_ spans: [BodySpan]) -> String {
        spans.map(\.text).joined()
    }
}

/// Turns a simple message's HTML into styled spans, and splits off the quoted
/// reply history while it does so.
///
/// This is a forgiving one-pass scanner, NOT a conformant HTML parser, and
/// that's the right shape for the job: it only ever runs on bodies
/// `SimpleBody.isSimple` has already vetted, unclosed and mis-nested tags are
/// endemic to real mail, and it must never throw on hostile input. Anything it
/// doesn't understand it ignores.
///
/// Deliberately NOT `NSAttributedString(data:options:[.documentType: .html])`:
/// that route is WebKit-backed (so it's main-thread-only and slow), and it
/// imports precisely the sender fonts and colors this path exists to discard.
///
/// Pure and non-isolated on purpose — all the hard logic is here and testable
/// without the main actor; mapping spans to real fonts is a separate, trivial
/// `@MainActor` step (`BodyAttributedString`).
enum MessageBodyParser {
    /// Tags that begin a new block, so a boundary is worth a blank line.
    private static let blockTags: Set<String> = [
        "p", "div", "blockquote", "pre", "hr", "center",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "dd", "dt",
    ]

    static func parse(html: String) -> ParsedBody {
        var state = ParseState()
        var scanner = TagScanner(html: html)
        while let token = scanner.next() {
            switch token {
            case .text(let raw):
                state.appendText(raw)
            case .open(let tag, let attributes, let selfClosing):
                state.openTag(tag, attributes: attributes)
                if selfClosing || voidTags.contains(tag) { state.closeTag(tag) }
            case .close(let tag):
                state.closeTag(tag)
            }
        }
        return state.finish()
    }

    /// Tags that never have a closing partner, so their style must not be left
    /// on the stack waiting for one.
    private static let voidTags: Set<String> = ["br", "hr", "img", "meta", "base", "wbr"]

    // MARK: - Parse state

    /// The scanner's running state: the inline-style stack, the list counters,
    /// the pending block break, and which half of the `ParsedBody` output is
    /// currently being written to.
    private struct ParseState {
        var body = ParsedBody()
        /// Once true, never false again: everything from the quote boundary to
        /// the end of the document is history.
        var inQuote = false
        /// Guards the bare-`<blockquote>` heuristic below — see `isQuoteBoundary`.
        var hasNewContent = false
        var style = BodySpan(text: "")
        /// Saved (tag, style-before-open) pairs, so a close restores exactly
        /// what its open changed and mis-nesting can't corrupt the rest.
        var stack: [(tag: String, style: BodySpan)] = []
        /// `nil` for an unordered list, else the next item's number.
        var listCounters: [Int?] = []
        /// 0 none, 1 line break, 2 blank line. Held rather than emitted so a
        /// break at the very start or end of a body never renders.
        var pendingBreak = 0
        var preDepth = 0

        mutating func appendText(_ raw: String) {
            let decoded = HTMLEntities.decode(raw)
            let text: String
            if preDepth > 0 {
                text = decoded
            } else {
                // Collapse HTML's insignificant whitespace. A run that is ONLY
                // whitespace still counts as a single space between words, but
                // must not resurrect a break we're deliberately holding.
                let collapsed = decoded.replacingOccurrences(
                    of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
                if collapsed.trimmingCharacters(in: .whitespaces).isEmpty {
                    if pendingBreak == 0 && !currentIsEmpty { emit(" ") }
                    return
                }
                text = collapsed
            }
            emit(text)
        }

        /// Writes into whichever half is active, merging into the previous span
        /// when the styling is identical so a paragraph doesn't become fifty
        /// one-character spans.
        mutating func emit(_ text: String) {
            guard !text.isEmpty else { return }
            var piece = text
            if pendingBreak > 0 {
                if !currentIsEmpty {
                    piece = String(repeating: "\n", count: pendingBreak) + piece
                }
                pendingBreak = 0
            }
            if !inQuote, !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasNewContent = true
            }
            if inQuote {
                append(piece, to: &body.quoted)
            } else {
                append(piece, to: &body.new)
            }
        }

        func append(_ text: String, to spans: inout [BodySpan]) {
            if let last = spans.last, last.styleKey == style.styleKey {
                spans[spans.count - 1].text += text
            } else {
                var span = style
                span.text = text
                spans.append(span)
            }
        }

        var currentIsEmpty: Bool {
            (inQuote ? body.quoted : body.new).isEmpty
        }

        mutating func openTag(_ tag: String, attributes: [String: String]) {
            if !inQuote, isQuoteBoundary(tag: tag, attributes: attributes) {
                inQuote = true
                pendingBreak = 0
                // The boundary element's own styling belongs to the history,
                // not to the reply — start it from a clean slate.
                style = BodySpan(text: "")
                stack.removeAll()
            }
            stack.append((tag, style))

            switch tag {
            case "b", "strong": style.bold = true
            case "i", "em", "cite", "var": style.italic = true
            case "u", "ins": style.underline = true
            case "code", "pre", "tt", "kbd", "samp":
                style.monospace = true
                if tag == "pre" { preDepth += 1 }
            case "h1", "h2", "h3", "h4", "h5", "h6": style.bold = true
            case "a":
                if let href = attributes["href"], let url = safeURL(href) { style.link = url }
            case "ul": listCounters.append(nil)
            case "ol": listCounters.append(1)
            case "li":
                pendingBreak = max(pendingBreak, 1)
                emit(listMarker())
                return
            case "br":
                pendingBreak = max(pendingBreak, 1)
                return
            default:
                break
            }
            if blockTags.contains(tag) { pendingBreak = max(pendingBreak, 2) }
        }

        /// The bullet or number for the current `<li>`, advancing the counter.
        mutating func listMarker() -> String {
            guard let counter = listCounters.last else { return "• " }
            guard let number = counter else { return "• " }
            listCounters[listCounters.count - 1] = number + 1
            return "\(number). "
        }

        mutating func closeTag(_ tag: String) {
            if tag == "pre" { preDepth = max(0, preDepth - 1) }
            if tag == "ul" || tag == "ol", !listCounters.isEmpty { listCounters.removeLast() }
            // Unwind to the matching open. A close with no open on the stack is
            // stray markup — ignore it rather than discarding unrelated styling.
            guard let index = stack.lastIndex(where: { $0.tag == tag }) else { return }
            style = stack[index].style
            stack.removeSubrange(index...)
            if blockTags.contains(tag) { pendingBreak = max(pendingBreak, 2) }
        }

        /// Whether this opening tag starts the quoted reply history.
        ///
        /// The first three markers are explicit and unambiguous — the client
        /// that wrote the reply labelled the quote itself. The fourth, a bare
        /// `<blockquote>`, is a heuristic, and it's guarded by `hasNewContent`
        /// for a specific reason: a message that OPENS with a blockquote is
        /// quote-first prose, and treating that as history would collapse the
        /// entire message and render it blank. Requiring some real text first
        /// means the worst case is a mid-message pull-quote landing behind the
        /// "···" toggle — one click away, never a blank message.
        func isQuoteBoundary(tag: String, attributes: [String: String]) -> Bool {
            let classes = attributes["class"] ?? ""
            if classes.contains("gmail_quote") { return true }          // Gmail
            if attributes["id"] == "divRplyFwdMsg" { return true }      // Outlook
            if tag == "blockquote" {
                if attributes["type"]?.lowercased() == "cite" { return true }   // Apple Mail
                return hasNewContent
            }
            return false
        }

        mutating func finish() -> ParsedBody {
            body.new = Self.tidied(body.new)
            body.quoted = Self.tidied(body.quoted)
            return body
        }

        /// Trims the leading/trailing whitespace a document's own scaffolding
        /// leaves behind, and drops spans that end up empty.
        static func tidied(_ spans: [BodySpan]) -> [BodySpan] {
            var result = spans
            while let first = result.first {
                let trimmed = String(first.text.drop(while: { $0 == "\n" || $0 == " " }))
                if trimmed.isEmpty { result.removeFirst() } else {
                    result[0].text = trimmed
                    break
                }
            }
            while let last = result.last {
                var text = last.text
                while let character = text.last, character == "\n" || character == " " {
                    text.removeLast()
                }
                if text.isEmpty { result.removeLast() } else {
                    result[result.count - 1].text = text
                    break
                }
            }
            return result
        }

        /// Only http/https/mailto ever become a tappable link — the same scheme
        /// allowlist `PlainTextLinkifier` enforces, so a body can't smuggle a
        /// `file:`/`javascript:`/custom-scheme link past either path.
        func safeURL(_ href: String) -> URL? {
            let trimmed = HTMLEntities.decode(href).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                ["http", "https", "mailto"].contains(scheme)
            else { return nil }
            return url
        }
    }
}

// MARK: - Tag scanning

/// The lexer: walks the document once, handing back text runs and tags.
/// Total by construction — every branch either consumes at least one character
/// or ends the scan, so no input can make it loop.
private struct TagScanner {
    enum Token {
        case text(String)
        case open(tag: String, attributes: [String: String], selfClosing: Bool)
        case close(String)
    }

    private let characters: [Character]
    private var index = 0

    init(html: String) {
        self.characters = Array(html)
    }

    mutating func next() -> Token? {
        guard index < characters.count else { return nil }
        if characters[index] == "<" {
            if let token = scanTag() { return token }
            // Not a real tag (a bare "<" in prose) — emit it as text so the
            // sender's "a < b" survives instead of vanishing.
            index += 1
            return .text("<")
        }
        var text = ""
        while index < characters.count, characters[index] != "<" {
            text.append(characters[index])
            index += 1
        }
        return .text(text)
    }

    /// Consumes a tag starting at `<`, or returns nil (leaving `index` put) if
    /// what follows isn't one.
    private mutating func scanTag() -> Token? {
        var cursor = index + 1
        guard cursor < characters.count else { return nil }

        // Comments and declarations carry no styling — skip them whole.
        if characters[cursor] == "!" {
            if matches("!--", at: cursor) {
                index = indexAfter("-->", from: cursor) ?? characters.count
            } else {
                index = indexAfter(">", from: cursor) ?? characters.count
            }
            return .text("")
        }

        let isClosing = characters[cursor] == "/"
        if isClosing { cursor += 1 }
        guard cursor < characters.count, characters[cursor].isLetter else { return nil }

        var name = ""
        while cursor < characters.count,
            characters[cursor].isLetter || characters[cursor].isNumber
                || characters[cursor] == ":" || characters[cursor] == "-"
                || characters[cursor] == "_" {
            name.append(characters[cursor])
            cursor += 1
        }

        var attributes: [String: String] = [:]
        var selfClosing = false
        // Attribute region. Quoted values may contain ">", so the terminator
        // is only honoured outside quotes.
        var quote: Character?
        var attributeText = ""
        while cursor < characters.count {
            let character = characters[cursor]
            if let open = quote {
                if character == open { quote = nil }
                attributeText.append(character)
            } else if character == "\"" || character == "'" {
                quote = character
                attributeText.append(character)
            } else if character == ">" {
                cursor += 1
                break
            } else {
                if character == "/" { selfClosing = true }
                attributeText.append(character)
            }
            cursor += 1
        }
        if !attributeText.isEmpty { attributes = Self.parseAttributes(attributeText) }

        index = cursor
        let lowered = name.lowercased()
        return isClosing
            ? .close(lowered)
            : .open(tag: lowered, attributes: attributes, selfClosing: selfClosing)
    }

    private func matches(_ needle: String, at position: Int) -> Bool {
        let chars = Array(needle)
        guard position + chars.count <= characters.count else { return false }
        for (offset, character) in chars.enumerated()
        where characters[position + offset] != character {
            return false
        }
        return true
    }

    private func indexAfter(_ needle: String, from position: Int) -> Int? {
        let chars = Array(needle)
        var cursor = position
        while cursor + chars.count <= characters.count {
            if matches(needle, at: cursor) { return cursor + chars.count }
            cursor += 1
        }
        return nil
    }

    /// Splits `name="value"` pairs. Lowercases names (HTML attribute names are
    /// case-insensitive) but never values — an href's case is load-bearing.
    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = attributeRegex else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            // Exactly one of the three value groups participates per match.
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                result[name] = ns.substring(with: match.range(at: group))
                break
            }
        }
        return result
    }

    private static let attributeRegex = try? NSRegularExpression(
        pattern: #"([a-zA-Z_:][a-zA-Z0-9:._-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
}
