import Foundation

/// The overlay composition every "effective labels" read shares — canonical
/// `message_labels` UNION pending `mutation_queue` adds, MINUS pending
/// `mutation_queue` removes (spec §5's optimistic-triage overlay). Before
/// this file, the identical three-subquery shape was hand-duplicated at four
/// call sites (`StoreReads.messageRow`, `SearchQuery.searchMessages`'
/// `.inbox` scope, `AIStore.sentMessages`, `ThreadRollup.effectiveLabelPresentInThread`)
/// — M5 Task 7 carry-forward: one shared fragment instead, so the overlay
/// rule only has one place to get right (or fix) instead of four.
enum EffectiveLabels {
    /// Returns `SELECT label_id FROM (...) AS present WHERE ... label_id
    /// NOT IN (...)` — the four call sites use this in two shapes:
    ///
    /// - Unfiltered (`label: nil`): every effective label for one message —
    ///   `StoreReads.messageRow`'s shape. Used as a top-level query with its
    ///   own `ORDER BY`/binder.
    /// - Filtered to one `label`: "does this message effectively carry
    ///   LABEL" — `SearchQuery`, `AIStore.sentMessages`, and
    ///   `ThreadRollup.effectiveLabelPresentInThread`'s shape. Meant to be
    ///   embedded directly inside `EXISTS(...)`: EXISTS only cares whether a
    ///   row comes back, not which column it selects, so `SELECT label_id`
    ///   here is exactly as good as those call sites' original `SELECT 1`.
    ///
    /// - Parameters:
    ///   - account: the SQL text identifying the account to correlate
    ///     against — a bound-parameter placeholder (e.g. `:acct`) or a
    ///     correlated column reference (e.g. `m.account_email`), depending
    ///     on the call site.
    ///   - messageID: same, for the message id column/placeholder (e.g.
    ///     `:mid` or `m.id`).
    ///   - label: same kind of SQL text for the specific label to filter to
    ///     (e.g. `'INBOX'` or `:label`) — `nil` for the unfiltered "list
    ///     every effective label" shape.
    ///
    ///   All three are always fixed, literal SQL text hardcoded by a call
    ///   site in this module — never end-user input — so building the
    ///   fragment via string interpolation is safe: this composes a SQL
    ///   *shape*, not a bound value, exactly like `GmailClient`'s
    ///   URL-building or `SearchQuery.safeMatchQuery`'s FTS5 phrase
    ///   construction compose their own textual shapes around
    ///   separately-bound/escaped values.
    static func fragment(account: String, messageID: String, label: String? = nil) -> String {
        let labelFilter = label.map { "label_id = \($0) AND " } ?? ""
        return """
            SELECT label_id FROM (
                SELECT label_id FROM message_labels
                WHERE account_email = \(account) AND message_id = \(messageID)
                UNION
                SELECT label_id FROM mutation_queue
                WHERE account_email = \(account) AND message_id = \(messageID) AND op = 'add'
            ) AS present
            WHERE \(labelFilter)label_id NOT IN (
                SELECT label_id FROM mutation_queue
                WHERE account_email = \(account) AND message_id = \(messageID) AND op = 'remove'
            )
            """
    }
}
