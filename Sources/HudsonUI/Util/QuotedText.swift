import Foundation

/// Splits a PLAIN-TEXT body into the new reply and the quoted history beneath
/// it — the text-path twin of `MessageBodyParser`'s structural quote
/// detection.
///
/// This path previously collapsed nothing at all: quote hiding lived only in
/// the JavaScript injected into the web view, so a plain-text reply rendered
/// its entire ancestry inline every time. Text has no `.gmail_quote` class to
/// key off, so detection is necessarily by convention — but the conventions
/// below are near-universal, having been emitted by essentially every mail
/// client for decades.
enum QuotedText {
    /// Returns the reply and its quoted history. `quoted` is empty when no
    /// boundary is found, in which case `new` is the input unchanged.
    static func split(_ plainText: String) -> (new: String, quoted: String) {
        let lines = plainText.components(separatedBy: "\n")
        guard let boundary = boundaryIndex(in: lines) else { return (plainText, "") }

        let new = lines[..<boundary].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = lines[boundary...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A boundary that leaves nothing above it isn't a boundary — the whole
        // message IS the quote (a bare forward, say). Collapsing it would show
        // an empty message, so leave it all visible.
        guard !new.isEmpty else { return (plainText, "") }
        return (new, quoted)
    }

    /// The first line index belonging to the history, or `nil` when there's
    /// none. Scans forward and takes the earliest marker, so a reply that both
    /// quotes and separates only ever splits once, at the top of the history.
    private static func boundaryIndex(in lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // A quoted run. Real mail marks every history line with ">", so
            // the first one is the top of the block.
            if trimmed.hasPrefix(">") { return index }

            // "-----Original Message-----" (Outlook, and many others).
            if trimmed.lowercased().hasPrefix("-----original message-----") { return index }

            // Outlook's horizontal rule between reply and history.
            if trimmed.count >= 10, trimmed.allSatisfy({ $0 == "_" }) { return index }

            // The attribution line: "On <date>, <someone> wrote:". Clients wrap
            // it freely, so accept it spread over up to three lines — the
            // terminating "wrote:" is what actually confirms the match, and
            // requiring it keeps an ordinary sentence starting with "On" from
            // truncating someone's message.
            if trimmed.hasPrefix("On ") || trimmed.hasPrefix("Am ") {
                var joined = trimmed
                for lookahead in 0..<3 {
                    if joined.hasSuffix("wrote:") { return index }
                    let next = index + lookahead + 1
                    guard next < lines.count else { break }
                    joined += " " + lines[next].trimmingCharacters(in: .whitespaces)
                }
                if joined.hasSuffix("wrote:") { return index }
            }
        }
        return nil
    }
}
