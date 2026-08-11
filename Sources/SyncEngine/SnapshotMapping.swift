import GmailKit
import Store

/// Maps Gmail DTOs to Store snapshots. The only place the two vocabularies meet.
enum SnapshotMapping {
    /// nil when the message lacks a parsable historyId (never observed in
    /// practice; guarding beats crashing on hostile data).
    static func snapshot(from message: GmailMessage) -> MessageSnapshot? {
        guard let historyID = Int64(message.historyId) else { return nil }
        return MessageSnapshot(
            id: message.id,
            threadID: message.threadId,
            historyID: historyID,
            internalDate: message.internalDate.flatMap(Int64.init) ?? 0,
            fromLine: message.header("From") ?? "",
            toLine: message.header("To") ?? "",
            subject: message.header("Subject") ?? "",
            snippet: message.snippet ?? "",
            labelIDs: message.labelIds ?? [],
            // M5 Task 5: persisted so a LATER reply to this message can
            // build the threading triple's In-Reply-To/References legs
            // without a live round-trip (spec §7.1). `nil` when the
            // fetch's format didn't request headers at all (e.g.
            // `format: "minimal"`'s labels-only patch never reaches this
            // mapper) or the message genuinely lacks the header.
            rfc822MessageID: message.header("Message-ID"),
            referencesHeader: message.header("References"))
    }
}
