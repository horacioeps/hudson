import Foundation

/// Pure text formatting for a message card's header and attachment chips.
///
/// Deliberately a free-standing enum rather than statics on `ThreadView`:
/// `View` is `@MainActor`, so anything declared on a view inherits that
/// isolation. These are pure string functions with no view state, and hanging
/// them off the view meant a non-isolated caller — a test, most obviously —
/// trapped at runtime inside `swift_task_checkIsolated` rather than simply
/// calling them. Keeping them here makes the isolation match the actual
/// requirement, which is none.
enum MessageHeaderText {
    /// "to you, David · Mon 2:14 PM" — the design's second header line.
    ///
    /// `To` is raw RFC 5322, so each address is reduced to something a person
    /// reads: the account owner becomes "you", a `Name <addr>` header becomes
    /// its display name, and a bare address falls back to its local part
    /// rather than dumping the full `someone@somewhere.example` into a line
    /// that has to fit beside the sender's name.
    ///
    /// Takes the two fields it needs rather than a whole `MessageRow` so a
    /// test can exercise it without standing up a database.
    static func recipientLine(toLine: String, internalDate: Int64, account: String) -> String {
        let time = InboxListView.formattedTime(epochMilliseconds: internalDate)
        let names = toLine
            .split(separator: ",")
            .map { shortRecipient(String($0), account: account) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return time }
        // Two recipients is where the line still reads naturally; past that a
        // count is more useful than a truncated list.
        let people = names.count > 2
            ? "\(names[0]), \(names[1]) +\(names.count - 2)"
            : names.joined(separator: ", ")
        return "to \(people) · \(time)"
    }

    static func shortRecipient(_ addressField: String, account: String) -> String {
        let address = SenderInfo.address(fromLine: addressField)
        if address.caseInsensitiveCompare(account) == .orderedSame { return "you" }
        let name = SenderInfo.name(fromLine: addressField)
        // `name` returns the whole field when there's no `Name <addr>` form,
        // which for a bare address is the address itself — use its local part.
        if name.caseInsensitiveCompare(address) == .orderedSame {
            return String(address.prefix(while: { $0 != "@" }))
        }
        return name
    }

    /// An SF Symbol standing in for the design's Phosphor file glyphs, matched
    /// on the broad kind rather than the exact type — an unknown MIME type
    /// falls back to a generic document rather than showing nothing.
    static func attachmentIcon(forMimeType mimeType: String) -> String {
        let type = mimeType.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type.contains("sheet") || type.contains("excel") || type.contains("csv") {
            return "tablecells"
        }
        return "doc"
    }

    /// Bytes as the design writes them — "1.2 MB", "84 KB". Decimal units, to
    /// match what Finder and Gmail both show for the same file.
    static func attachmentSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
