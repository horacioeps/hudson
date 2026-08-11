import Foundation
import Store

/// One-shot optimistic triage actions, each enqueuing exactly the label
/// delta Gmail's own affordance would produce, via `enqueueMutation`
/// (Store, Task 3). Because `enqueueMutation` recomputes `thread_rollup` in
/// the SAME transaction, a caller never mutates a view model's `rows` after
/// calling one of these — the next `observeInboxThreads` emission already
/// reflects it (see `InboxModel`'s `archiveSelected`/`toggleStarSelected`/
/// `toggleReadSelected`, its only current callers).
public enum Triage {
    /// Archiving is Gmail's own semantics for "leave the inbox": drop the
    /// `INBOX` label. Read state, star, and every other label are untouched.
    public static func archive(
        messageID: String, account: String, database: HudsonDatabase
    ) async throws {
        try await database.enqueueMutation(
            messageID: messageID, labelID: "INBOX", op: .remove, account: account, now: now())
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

    /// Gmail models "read" as the ABSENCE of the `UNREAD` label.
    public static func markRead(
        messageID: String, account: String, database: HudsonDatabase
    ) async throws {
        try await database.enqueueMutation(
            messageID: messageID, labelID: "UNREAD", op: .remove, account: account, now: now())
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
