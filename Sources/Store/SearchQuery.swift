import Foundation
import GRDB

/// One full-text search result — a `messages` row joined back from an
/// `fts_messages` hit via `message_seq` (see `HudsonDatabase.searchMessages`).
public struct SearchHit: Sendable, Equatable {
    public let messageID: String
    public let threadID: String
    public let subject: String
    public let fromLine: String
    public let snippet: String
    public let internalDate: Int64
}

/// Which mailbox subset a search is scoped to.
public enum SearchScope: Sendable {
    /// Every indexed message, regardless of label.
    case all
    /// Only messages whose EFFECTIVE labels (canonical `message_labels` with
    /// pending `mutation_queue` deltas applied — see `searchMessages`)
    /// currently include INBOX.
    case inbox
}

extension HudsonDatabase {
    /// Instant local full-text search over `fts_messages` — bm25-ranked,
    /// bounded, and safe against a fully adversarial `query` string.
    ///
    /// **2-char floor:** `query`, trimmed, must be at least 2 characters —
    /// `fts_messages`' `prefix='2 3 4'` index only accelerates prefixes of
    /// 2+ characters, so a shorter query would force a full index scan on
    /// every keystroke. Below that floor this returns `[]` without touching
    /// the database at all (the search-as-you-type caller is expected to
    /// call this on every keystroke; a 1-character query is a guaranteed
    /// near-miss anyway, so there's nothing useful to bound).
    ///
    /// **Injection-safe MATCH:** `query` is untrusted user input, and FTS5's
    /// MATCH syntax is a small query language of its own — bareword
    /// operators (`AND`/`OR`/`NOT`/`NEAR`), column filters (`subject:`,
    /// `{col1 col2}:`), grouping, and initial-token/prefix operators (`^`,
    /// `*`) — so it is never interpolated raw. Instead `query` is split on
    /// whitespace into independent terms, each term is turned into a
    /// double-quoted FTS5 phrase (escaping an embedded `"` as `""`, the
    /// FTS5 literal-quote rule) with a trailing `*` for prefix matching,
    /// and the phrases are joined with spaces — FTS5's implicit AND. A
    /// quoted phrase's contents are always literal to FTS5: none of the
    /// syntax above is interpreted inside one, so every term the caller
    /// typed is guaranteed to mean "search for this literal text",
    /// however much it looks like MATCH syntax — e.g. `foo "bar` becomes
    /// `"foo"* """bar"*`. See `safeMatchQuery`.
    ///
    /// **bm25 ranking:** `bm25(fts_messages, 10.0, 5.0, 2.0, 1.0)` weights
    /// `fts_messages`' `subject, from_addr, to_addr, body` columns in that
    /// order, so a subject hit ranks well above a body-only hit. bm25's
    /// scores are a cost (lower/more negative is a better match), and SQL's
    /// default `ORDER BY` is ascending, so no explicit direction is needed
    /// to get best-match-first.
    ///
    /// **Join-back:** `fts_messages`' implicit rowid is `message_seq.seq`
    /// (Task 1) — a dense integer allocated once per `(account, message)`
    /// and stable for that message's whole lifetime — so each hit is joined
    /// `fts_messages.rowid = message_seq.seq`, then `message_seq`'s
    /// `(account_email, message_id)` back onto `messages` for the fields
    /// `SearchHit` needs. `message_seq.account_email` also scopes results
    /// to the requesting account, since `fts_messages` itself carries no
    /// account column.
    ///
    /// **Overlay scope:** `.inbox` adds an `EXISTS` filter over the same
    /// effective-labels composition `StoreReads.messageRow` and
    /// `ThreadRollup.effectiveLabelPresentInThread` use — (canonical
    /// `message_labels` ∪ pending `mutation_queue` adds) − pending
    /// `mutation_queue` removes — evaluated per hit message rather than per
    /// thread, so an optimistically-archived message drops out of an
    /// in-inbox search on the very next call, before the archive ever
    /// reaches Gmail.
    public func searchMessages(
        account: String, query: String, limit: Int, scope: SearchScope = .all
    ) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let match = Self.safeMatchQuery(trimmed)

        return try await writer.read { db in
            var sql = """
                SELECT m.id AS message_id, m.thread_id, m.subject, m.from_line,
                       m.snippet, m.internal_date
                FROM fts_messages
                JOIN message_seq ON message_seq.seq = fts_messages.rowid
                JOIN messages m
                    ON m.account_email = message_seq.account_email AND m.id = message_seq.message_id
                WHERE fts_messages MATCH ? AND message_seq.account_email = ?
                """
            var arguments: StatementArguments = [match, account]
            if case .inbox = scope {
                sql += """

                    AND EXISTS (
                        SELECT 1 FROM (
                            SELECT label_id FROM message_labels
                            WHERE account_email = m.account_email AND message_id = m.id
                            UNION
                            SELECT label_id FROM mutation_queue
                            WHERE account_email = m.account_email AND message_id = m.id AND op = 'add'
                        ) AS present
                        WHERE label_id = 'INBOX'
                        AND label_id NOT IN (
                            SELECT label_id FROM mutation_queue
                            WHERE account_email = m.account_email AND message_id = m.id AND op = 'remove'
                        )
                    )
                    """
            }
            sql += " ORDER BY bm25(fts_messages, 10.0, 5.0, 2.0, 1.0) LIMIT ?"
            arguments += [limit]
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map(Self.searchHit(from:))
        }
    }

    static func searchHit(from row: Row) -> SearchHit {
        SearchHit(
            messageID: row["message_id"], threadID: row["thread_id"], subject: row["subject"],
            fromLine: row["from_line"], snippet: row["snippet"], internalDate: row["internal_date"])
    }

    /// Turns untrusted `query` into a safe FTS5 MATCH string: each
    /// whitespace-separated term becomes its own double-quoted, prefix-
    /// matched phrase — `foo "bar` → `"foo"* """bar"*` (the lone `"` in
    /// `"bar` is escaped to `""`, then the whole term is wrapped in its own
    /// pair of quotes) — so every term is literal content to FTS5's parser,
    /// never syntax. Joining phrases with a bare space is FTS5's implicit
    /// AND, so a multi-term query still requires every term to match (in
    /// any column), matching ordinary search-box expectations.
    static func safeMatchQuery(_ query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { term in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }
}
