import Foundation
import Store

/// One-shot optimistic triage actions, each enqueuing exactly the label
/// delta Gmail's own affordance would produce, via `enqueueMutation`
/// (Store, Task 3). Because `enqueueMutation` recomputes `thread_rollup` in
/// the SAME transaction, a caller never mutates a view model's `rows` after
/// calling one of these — the next `observeInboxThreads` emission already
/// reflects it (see `InboxModel`'s `archiveSelected`/`toggleStarSelected`/
/// `toggleReadSelected`, its only current callers).
///
/// **Thread-level vs. message-level:** `thread_rollup.in_inbox`/`unread`
/// are OR-aggregates across EVERY message in the thread
/// (`ThreadRollup.recomputeThreadFlags`/`effectiveLabelPresentInThread`) —
/// true if ANY message still effectively carries the label. So archiving or
/// mark-reading only the thread's newest message (`lastMessageID`) is a
/// silent no-op on a multi-message thread whenever an OLDER message still
/// carries `INBOX`/`UNREAD`: the rollup recomputes right back to `true` and
/// the thread never leaves `inboxThreads`. `archiveThread`/`markReadThread`
/// below fix that by enqueuing the delta on every message in the thread
/// that actually carries the label — the same "leave the inbox"/"mark this
/// conversation read" a real Gmail client performs. Starring and marking
/// unread, by contrast, are genuinely single-message actions in Gmail
/// itself (you star/re-flag-unread one message, not a whole thread), so
/// `star`/`unstar`/`markUnread` stay scoped to one `messageID`.
public enum Triage {
    /// Archives every message in the thread that's still effectively in
    /// the inbox — the fix for the OR-aggregate rollup described above.
    /// `threadMessages` returns overlay-aware `labelIDs` (pending
    /// mutations already applied), so a message whose `INBOX` removal is
    /// already queued is correctly skipped rather than re-enqueued.
    public static func archiveThread(
        threadID: String, account: String, database: HudsonDatabase
    ) async throws {
        let time = now()
        for message in try await database.threadMessages(threadID: threadID, account: account)
        where message.labelIDs.contains("INBOX") {
            try await database.enqueueMutation(
                messageID: message.id, labelID: "INBOX", op: .remove, account: account, now: time)
        }
    }

    public static func star(
        messageID: String, account: String, database: HudsonDatabase
    ) async throws {
        try await database.enqueueMutation(
            messageID: messageID, labelID: "STARRED", op: .add, account: account, now: now())
    }

    public static func unstar(
        messageID: String, account: String, database: HudsonDatabase
    ) async throws {
        try await database.enqueueMutation(
            messageID: messageID, labelID: "STARRED", op: .remove, account: account, now: now())
    }

    /// Marks every effectively-unread message in the thread read — Gmail
    /// models "read" as the ABSENCE of `UNREAD`, and (like `archiveThread`)
    /// the rollup's `unread` flag is an OR across the whole thread, so a
    /// single-message removal would leave it `true` whenever another
    /// message is still unread.
    public static func markReadThread(
        threadID: String, account: String, database: HudsonDatabase
    ) async throws {
        let time = now()
        for message in try await database.threadMessages(threadID: threadID, account: account)
        where message.labelIDs.contains("UNREAD") {
            try await database.enqueueMutation(
                messageID: message.id, labelID: "UNREAD", op: .remove, account: account, now: time)
        }
    }

    public static func markUnread(
        messageID: String, account: String, database: HudsonDatabase
    ) async throws {
        try await database.enqueueMutation(
            messageID: messageID, labelID: "UNREAD", op: .add, account: account, now: now())
    }

    /// TODO(M?): splits are rule-derived (`SplitInbox.computeSplit`, driven
    /// by `split_rules`) — there is no Gmail label id that moves a message
    /// into one, the way `INBOX`/`STARRED`/`UNREAD` do. A real "move to
    /// split" would need either a per-message rule override or a new
    /// locally-owned label, neither of which exists yet. Stubbed as a
    /// no-op (rather than omitted) so the triage palette (a later task) has
    /// a stable signature to wire its "Move to…" action against now, and
    /// gets real behavior later with no call-site change.
    public static func moveToSplit(
        messageID: String, splitName: String, account: String, database: HudsonDatabase
    ) async throws {
        // Intentionally empty — see doc comment above.
    }

    /// Shared "now" for every triage mutation, in the same unit
    /// `thread_rollup`/`messages.internal_date` use (ms since epoch), per
    /// `enqueueMutation`'s `now` parameter contract.
    private static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
