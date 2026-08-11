import GRDB

extension HudsonDatabase {
    /// Newest-first threads that carry a given effective label — the surface
    /// behind the sidebar's Starred / Sent / <user label> folders (Inbox has
    /// its own `inboxThreads`). A thread qualifies if ANY of its messages
    /// effectively carries `labelID` (canonical `message_labels` with the
    /// pending `mutation_queue` overlay applied — the same optimistic-triage
    /// composition every other effective-label read uses, via
    /// `EffectiveLabels.fragment`). Reads `thread_rollup` for the row shape
    /// (identical columns to `inboxThreads`) and is deliberately NOT filtered
    /// by `in_inbox`, since Sent/archived threads live outside the inbox.
    public func threadsWithLabel(
        account: String, labelID: String, limit: Int
    ) async throws -> [ThreadRow] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: Self.threadsWithLabelSQL, arguments: Self.threadsWithLabelArgs(account: account, labelID: labelID, limit: limit))
                .map(Self.threadRow(from:))
        }
    }

    /// Reactive twin of `threadsWithLabel` — re-emits whenever a triage flips
    /// the effective label set (e.g. star/unstar), so a folder list stays live
    /// exactly like the inbox does.
    public func observeThreadsWithLabel(
        account: String, labelID: String, limit: Int
    ) -> AsyncValueObservation<[ThreadRow]> {
        ValueObservation
            .tracking { db in
                try Row.fetchAll(db, sql: Self.threadsWithLabelSQL, arguments: Self.threadsWithLabelArgs(account: account, labelID: labelID, limit: limit))
                    .map(Self.threadRow(from:))
            }
            .values(in: writer)
    }

    /// `:label` is bound once and reused inside `EffectiveLabels.fragment`'s
    /// `label_id = :label` filter (GRDB named arguments), so the untrusted
    /// label value is never interpolated into SQL text.
    private static let threadsWithLabelSQL = """
        SELECT tr.thread_id, tr.last_message_id, tr.subject, tr.snippet, tr.from_summary,
               tr.split_key, tr.category, tr.last_message_at, tr.message_count,
               tr.unread, tr.in_inbox, tr.has_attachment
        FROM thread_rollup tr
        WHERE tr.account_email = :acct
        AND EXISTS (
            SELECT 1 FROM messages m
            WHERE m.account_email = tr.account_email AND m.thread_id = tr.thread_id
            AND EXISTS ( \(EffectiveLabels.fragment(account: "m.account_email", messageID: "m.id", label: ":label")) )
        )
        ORDER BY tr.last_message_at DESC, tr.thread_id DESC LIMIT :limit
        """

    private static func threadsWithLabelArgs(account: String, labelID: String, limit: Int) -> StatementArguments {
        ["acct": account, "label": labelID, "limit": limit]
    }
}
