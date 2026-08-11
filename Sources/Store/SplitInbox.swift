import GRDB

/// One configured split-inbox rule — an ordered predicate that routes a
/// thread's newest message into a named split ("Important" / "Team" /
/// "News" / ...). Rules are evaluated in ascending `ordinal` order and the
/// FIRST match wins — see `SplitInbox.computeSplit`.
public struct SplitRule: Sendable, Equatable {
    public let ordinal: Int
    public let kind: SplitPredicateKind
    public let value: String
    public let splitName: String

    /// Memberwise — callers build rules to hand to `setSplitRules`.
    public init(ordinal: Int, kind: SplitPredicateKind, value: String, splitName: String) {
        self.ordinal = ordinal
        self.kind = kind
        self.value = value
        self.splitName = splitName
    }
}

/// What a `SplitRule`'s `value` is matched against — see
/// `SplitInbox.computeSplit` for each kind's exact match semantics.
public enum SplitPredicateKind: String, Sendable, Equatable {
    case sender
    case domain
    case listid
    case category
}

extension HudsonDatabase {
    /// Replaces the account's ENTIRE ordered rule set: deletes whatever is
    /// currently stored, then inserts `rules` (in the order given, one row
    /// per rule). Simple replace-all rather than a diffing update — the
    /// rule set is small (user-configured, not sync-scale data) and a
    /// caller editing rules already has the full desired set in hand (e.g.
    /// a settings UI that lets someone reorder/add/remove splits).
    public func setSplitRules(_ rules: [SplitRule], account: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM split_rules WHERE account_email = ?", arguments: [account])
            for rule in rules {
                try db.execute(
                    sql: """
                        INSERT INTO split_rules
                            (account_email, ordinal, predicate_kind, predicate_value, split_name)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        account, rule.ordinal, rule.kind.rawValue, rule.value, rule.splitName,
                    ])
            }
        }
    }

    /// The account's split rules, ordered by `ordinal` ascending — the same
    /// order `computeSplit` evaluates them in ("first match wins").
    public func splitRules(account: String) async throws -> [SplitRule] {
        try await writer.read { db in try SplitInbox.fetchRules(account: account, db: db) }
    }
}

/// Pure split-key derivation, plus the synchronous (in-transaction) rule
/// lookup `ThreadRollup` uses — `ThreadRollup.maintainRollup`/
/// `recomputeThreadRollup` run inside an already-open write transaction and
/// can't `await` the public async `splitRules(account:)` above (Store's "no
/// await in transaction closures" invariant), so `fetchRules` is the
/// synchronous twin they call instead.
enum SplitInbox {
    /// Gmail's `CATEGORY_*` label ids, mapped to the friendly names
    /// `computeSplit` reports as `category` — and, absent any matching
    /// rule, as the fallback `splitKey` too (Gmail's own
    /// Promotions/Social/Updates/Forums/Personal tabs become split tabs
    /// with ZERO rule configuration).
    private static let categoryNames: [String: String] = [
        "CATEGORY_PROMOTIONS": "promotions",
        "CATEGORY_SOCIAL": "social",
        "CATEGORY_UPDATES": "updates",
        "CATEGORY_FORUMS": "forums",
        "CATEGORY_PERSONAL": "personal",
    ]

    /// Reads one account's split rules, ordered by `ordinal` ascending, from
    /// inside an already-open transaction/connection.
    static func fetchRules(account: String, db: Database) throws -> [SplitRule] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT ordinal, predicate_kind, predicate_value, split_name FROM split_rules
                WHERE account_email = ? ORDER BY ordinal ASC
                """,
            arguments: [account]
        ).compactMap { row in
            guard let kind = SplitPredicateKind(rawValue: row["predicate_kind"] as String) else {
                return nil  // defensive: a hand-edited/foreign row with an unknown kind is skipped, not fatal
            }
            return SplitRule(
                ordinal: row["ordinal"], kind: kind, value: row["predicate_value"],
                splitName: row["split_name"])
        }
    }

    /// Pure: derives `(splitKey, category)` for ONE message from its
    /// `From:` line, `List-Id` header (if known), and label set, against
    /// the account's ordered rules.
    ///
    /// - `category` is the friendly name of the message's `CATEGORY_*`
    ///   label (`categoryNames`), or `""` if it carries none. A message
    ///   carries at most one Gmail category label in practice; if more than
    ///   one somehow appears, the first found (in `categoryLabels`' given
    ///   order) wins.
    /// - `splitKey`: rules are tried in `rules`' given order (callers pass
    ///   them pre-sorted by `ordinal`, e.g. via `fetchRules`/`splitRules`)
    ///   and the FIRST whose predicate matches wins — `splitKey` becomes
    ///   that rule's `splitName`. Predicate semantics:
    ///     - `.sender`: `fromLine` contains the rule's `value` (an email
    ///       address), case-insensitively.
    ///     - `.domain`: the domain portion of `fromLine`'s address equals
    ///       `value`, case-insensitively.
    ///     - `.listid`: `listID == value`, case-insensitively (consistent
    ///       with `.sender`/`.domain`). `listID` is `nil` when unknown (see
    ///       below) and a nil `listID` never matches.
    ///     - `.category`: the derived `category` (above) equals `value`.
    ///   If NO rule matches, `splitKey` falls back to `category` when
    ///   non-empty — so Gmail's own categories become split tabs for free —
    ///   else `"primary"`.
    ///
    /// `listID` is the message's `List-Id` header. **Limitation:**
    /// `MessageSnapshot` does not carry it today (`SyncEngine`'s
    /// `SnapshotMapping` never extracts a `List-Id` header), so every
    /// caller in this codebase currently passes `nil` and `.listid` rules
    /// never match yet. `computeSplit` itself is written against the
    /// general contract (an optional `listID`) so that adding `List-Id`
    /// extraction later is a pure `SnapshotMapping`/`MessageSnapshot`
    /// change with no update needed here. `.sender`/`.domain`/`.category`
    /// are the primary predicates until then.
    static func computeSplit(
        fromLine: String, listID: String?, categoryLabels: [String], rules: [SplitRule]
    ) -> (splitKey: String, category: String) {
        let category = categoryLabels.compactMap { categoryNames[$0] }.first ?? ""
        let fromLineLowercased = fromLine.lowercased()
        let domain = Self.domain(ofFromLine: fromLineLowercased)

        for rule in rules {
            let matched: Bool
            switch rule.kind {
            case .sender:
                matched = fromLineLowercased.contains(rule.value.lowercased())
            case .domain:
                matched = !domain.isEmpty && domain == rule.value.lowercased()
            case .listid:
                matched = listID.map { $0.lowercased() == rule.value.lowercased() } ?? false
            case .category:
                matched = !category.isEmpty && category == rule.value
            }
            if matched {
                return (rule.splitName, category)
            }
        }
        // Gmail's Primary tab IS CATEGORY_PERSONAL, and category-less mail
        // belongs there too — route both to the "primary" split so they land
        // in the always-present Primary tab. Otherwise every real Gmail
        // account (whose inbox mail all carries a CATEGORY_* label) shows an
        // empty Primary while its actual primary mail hides under "personal".
        let fallbackKey = (category.isEmpty || category == "personal") ? "primary" : category
        return (fallbackKey, category)
    }

    /// Extracts the domain from a (lowercased) raw `From:` header — whatever
    /// follows the last `@` up to (but not including) a closing `>`,
    /// whitespace, comma, or the string's end. `""` if no `@` is present.
    private static func domain(ofFromLine fromLine: String) -> String {
        guard let at = fromLine.lastIndex(of: "@") else { return "" }
        let afterAt = fromLine[fromLine.index(after: at)...]
        let end = afterAt.firstIndex(where: { $0 == ">" || $0 == "," || $0.isWhitespace })
            ?? afterAt.endIndex
        return String(afterAt[..<end])
    }
}
