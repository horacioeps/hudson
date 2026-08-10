import GRDB
import Testing
@testable import Store

private func snap(
    _ id: String, thread: String = "t1", date: Int64,
    from: String = "ada@x.com", labels: [String] = [], subject: String = "s"
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: "you@x.com", subject: subject, snippet: "sn", labelIDs: labels)
}

private func rollup(_ db: HudsonDatabase, account: String, thread: String) async throws -> (splitKey: String, category: String)? {
    try await db.writer.read { conn in
        guard let row = try Row.fetchOne(
            conn,
            sql: "SELECT split_key, category FROM thread_rollup WHERE account_email = ? AND thread_id = ?",
            arguments: [account, thread]
        ) else { return nil }
        return (row["split_key"], row["category"])
    }
}

/// Counts SQL statements referencing `split_rules` traced on one connection
/// — proves rules are loaded ONCE per batch, not re-queried per message.
/// `@unchecked Sendable`: the trace callback fires synchronously on the
/// database's own serial queue, and this test drives it with sequential
/// `await`s (never concurrently) — mirrors `ThreadRollupTests.StatementCounter`.
private final class SplitRulesQueryCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

// MARK: - computeSplit: pure function

@Test func computeSplitMapsGmailCategoryLabelsToFriendlyNamesWithNoRulesConfigured() {
    let cases: [(String, String)] = [
        ("CATEGORY_PROMOTIONS", "promotions"),
        ("CATEGORY_SOCIAL", "social"),
        ("CATEGORY_UPDATES", "updates"),
        ("CATEGORY_FORUMS", "forums"),
        ("CATEGORY_PERSONAL", "personal"),
    ]
    for (label, friendlyName) in cases {
        let result = SplitInbox.computeSplit(
            fromLine: "ada@x.com", listID: nil, categoryLabels: ["INBOX", label], rules: [])
        #expect(result.category == friendlyName)
        #expect(result.splitKey == friendlyName)  // Gmail categories become split tabs for free
    }
}

@Test func computeSplitWithNoCategoryAndNoMatchingRuleDefaultsToPrimary() {
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: nil, categoryLabels: ["INBOX"], rules: [])
    #expect(result.category == "")
    #expect(result.splitKey == "primary")
}

@Test func computeSplitSenderRuleMatchesFromLineContainingTheEmail() {
    let rules = [SplitRule(ordinal: 0, kind: .sender, value: "ada@x.com", splitName: "Ada")]
    let result = SplitInbox.computeSplit(
        fromLine: "Ada Lovelace <ada@x.com>", listID: nil, categoryLabels: [], rules: rules)
    #expect(result.splitKey == "Ada")
}

@Test func computeSplitDomainRuleMatchesFromLinesDomain() {
    let rules = [SplitRule(ordinal: 0, kind: .domain, value: "x.com", splitName: "Team")]
    let result = SplitInbox.computeSplit(
        fromLine: "Ada Lovelace <ada@x.com>", listID: nil, categoryLabels: [], rules: rules)
    #expect(result.splitKey == "Team")
}

@Test func computeSplitDomainRuleDoesNotMatchADifferentDomain() {
    let rules = [SplitRule(ordinal: 0, kind: .domain, value: "other.com", splitName: "Team")]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: nil, categoryLabels: [], rules: rules)
    #expect(result.splitKey == "primary")
}

@Test func computeSplitCategoryRuleMatchesTheDerivedCategory() {
    let rules = [SplitRule(ordinal: 0, kind: .category, value: "promotions", splitName: "Deals")]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: nil, categoryLabels: ["CATEGORY_PROMOTIONS"], rules: rules)
    #expect(result.splitKey == "Deals")
    #expect(result.category == "promotions")  // category field is the real category, not the split name
}

@Test func computeSplitListIDRuleMatchesWhenListIDProvided() {
    let rules = [SplitRule(ordinal: 0, kind: .listid, value: "list.example.com", splitName: "Newsletters")]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: "list.example.com", categoryLabels: [], rules: rules)
    #expect(result.splitKey == "Newsletters")
}

@Test func computeSplitListIDRuleMatchesCaseInsensitively() {
    // Minor fix: listid matching is now case-insensitive, consistent with
    // sender/domain — dormant until List-Id extraction exists, but the
    // predicate itself must behave consistently once it does.
    let rules = [SplitRule(ordinal: 0, kind: .listid, value: "list.example.com", splitName: "Newsletters")]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: "List.Example.COM", categoryLabels: [], rules: rules)
    #expect(result.splitKey == "Newsletters")
}

@Test func computeSplitListIDRuleNeverMatchesWhenListIDIsNil() {
    // Documented limitation: MessageSnapshot doesn't carry List-Id today.
    let rules = [SplitRule(ordinal: 0, kind: .listid, value: "list.example.com", splitName: "Newsletters")]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: nil, categoryLabels: [], rules: rules)
    #expect(result.splitKey == "primary")
}

@Test func computeSplitFirstMatchingOrderedRuleWins() {
    let rules = [
        SplitRule(ordinal: 0, kind: .domain, value: "x.com", splitName: "First"),
        SplitRule(ordinal: 1, kind: .sender, value: "ada@x.com", splitName: "Second"),
    ]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: nil, categoryLabels: [], rules: rules)
    #expect(result.splitKey == "First")  // both rules match; ordinal-0 wins
}

@Test func computeSplitFallsThroughNonMatchingRulesToALaterMatch() {
    let rules = [
        SplitRule(ordinal: 0, kind: .sender, value: "someone-else@x.com", splitName: "Nope"),
        SplitRule(ordinal: 1, kind: .domain, value: "x.com", splitName: "Team"),
    ]
    let result = SplitInbox.computeSplit(
        fromLine: "ada@x.com", listID: nil, categoryLabels: [], rules: rules)
    #expect(result.splitKey == "Team")
}

// MARK: - split_rules CRUD

@Test func setAndGetSplitRulesRoundTripsOrderedByOrdinal() async throws {
    let db = try HudsonDatabase.inMemory()
    let rules = [
        SplitRule(ordinal: 1, kind: .domain, value: "x.com", splitName: "Team"),
        SplitRule(ordinal: 0, kind: .sender, value: "ada@x.com", splitName: "Ada"),
    ]
    try await db.setSplitRules(rules, account: "x")
    let fetched = try await db.splitRules(account: "x")
    #expect(fetched.map(\.ordinal) == [0, 1])
    #expect(fetched.map(\.splitName) == ["Ada", "Team"])
    #expect(fetched == [rules[1], rules[0]])
}

@Test func setSplitRulesReplacesTheExistingSet() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setSplitRules(
        [SplitRule(ordinal: 0, kind: .sender, value: "ada@x.com", splitName: "Ada")], account: "x")
    try await db.setSplitRules(
        [SplitRule(ordinal: 0, kind: .domain, value: "x.com", splitName: "Team")], account: "x")
    let fetched = try await db.splitRules(account: "x")
    #expect(fetched.map(\.splitName) == ["Team"])
}

@Test func splitRulesAreScopedPerAccount() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setSplitRules(
        [SplitRule(ordinal: 0, kind: .sender, value: "ada@x.com", splitName: "Ada")], account: "x")
    try await db.setSplitRules(
        [SplitRule(ordinal: 0, kind: .sender, value: "bob@y.com", splitName: "Bob")], account: "y")
    #expect(try await db.splitRules(account: "x").map(\.splitName) == ["Ada"])
    #expect(try await db.splitRules(account: "y").map(\.splitName) == ["Bob"])
}

// MARK: - ThreadRollup maintenance writes split_key/category

@Test func maintainRollupWritesCategoryFromGmailLabelWithNoRulesConfigured() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "x")
    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.category == "promotions")
    #expect(row.splitKey == "promotions")  // free split tab, zero rule configuration
}

@Test func maintainRollupDefaultsToPrimaryWhenNoCategoryAndNoRuleMatches() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX"]), account: "x")
    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.category == "")
    #expect(row.splitKey == "primary")
}

@Test func maintainRollupAppliesAConfiguredRuleOverTheCategoryFallback() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setSplitRules(
        [SplitRule(ordinal: 0, kind: .sender, value: "ada@x.com", splitName: "Ada")], account: "x")
    _ = try await db.applySnapshot(
        snap("m1", date: 1, from: "ada@x.com", labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "x")
    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.splitKey == "Ada")       // rule wins over the category fallback
    #expect(row.category == "promotions")  // category field still reflects the real category
}

@Test func maintainRollupOnlyUpdatesSplitKeyWhenTheApplyingSnapshotIsTheNewest() async throws {
    let db = try HudsonDatabase.inMemory()
    // Newest message first: CATEGORY_PROMOTIONS, so split_key becomes "promotions".
    _ = try await db.applySnapshot(
        snap("m2", date: 2, labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "x")
    // An OLDER message with no category arrives after — must not downgrade
    // the rollup's split_key/category (mirrors subject/snippet's newest-wins rule).
    _ = try await db.applySnapshot(snap("m1", date: 1, labels: ["INBOX"]), account: "x")
    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.category == "promotions")
    #expect(row.splitKey == "promotions")
}

@Test func recomputeThreadRollupRecomputesSplitKeyForTheSurvivingNewestMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX"]), account: "x")
    _ = try await db.applySnapshot(
        snap("m2", date: 2, labels: ["INBOX", "CATEGORY_SOCIAL"]), account: "x")
    #expect(try await rollup(db, account: "x", thread: "t1")?.splitKey == "social")
    // Deleting the newest message (m2) must re-derive split_key from the
    // surviving newest (m1, no category) — a full rebuild, not an incremental delta.
    _ = try await db.applyHistoryChanges([HistoryChange(kind: .deleted(id: "m2"))], account: "x")
    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.category == "")
    #expect(row.splitKey == "primary")
}

@Test func batchApplyLoadsSplitRulesOnceNotPerMessage() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.setSplitRules(
        [SplitRule(ordinal: 0, kind: .sender, value: "ada@x.com", splitName: "Ada")], account: "x")
    let counter = SplitRulesQueryCounter()
    try await db.writer.write { conn in
        conn.trace { event in
            if case .statement(let statement) = event, statement.sql.contains("split_rules") {
                counter.increment()
            }
        }
    }
    _ = try await db.applySnapshots(
        [
            snap("m1", date: 1, labels: []),
            snap("m2", date: 2, labels: []),
            snap("m3", date: 3, labels: []),
        ], account: "x")
    #expect(counter.count == 1)  // one rules SELECT for the whole batch, not one per message
}

// MARK: - Fix round 1: .labels-only events refresh split/category too

@Test func labelsEventRefreshesSplitKeyWhenNewestMessageIsRecategorized() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "x")
    #expect(try await rollup(db, account: "x", thread: "t1")?.splitKey == "promotions")

    // Gmail (the user dragging between tabs, or the classifier revising
    // already-delivered mail) re-categorizes the message via a pure
    // `.labels` event — no full snapshot ever re-touches this single-
    // message thread again, so before this fix the rollup stayed stuck at
    // "promotions" forever.
    _ = try await db.applyHistory(
        [HistoryChange(kind: .labels(id: "m1", historyID: 5, labelIDs: ["INBOX", "CATEGORY_UPDATES"]))],
        newCursor: 5, account: "x")

    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.category == "updates")
    #expect(row.splitKey == "updates")
}

@Test func batchOfLabelsEventsOnTheSameThreadDedupsSplitRefreshToOnce() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "x", clientID: "c", consentedAt: .now)
    _ = try await db.applySnapshot(
        snap("m1", date: 1, labels: ["INBOX", "CATEGORY_PROMOTIONS"]), account: "x")

    let counter = SplitRulesQueryCounter()
    try await db.writer.write { conn in
        conn.trace { event in
            if case .statement(let statement) = event,
                statement.sql.contains("id, from_line FROM messages") {
                counter.increment()
            }
        }
    }
    // Two `.labels` events, BOTH touching the same message/thread, in ONE
    // batch — the split refresh must not redo the newest-message lookup
    // once per event.
    _ = try await db.applyHistoryChanges(
        [
            HistoryChange(kind: .labels(id: "m1", historyID: 5, labelIDs: ["INBOX", "CATEGORY_UPDATES"])),
            HistoryChange(kind: .labels(id: "m1", historyID: 6, labelIDs: ["INBOX", "CATEGORY_SOCIAL"])),
        ], account: "x")
    #expect(counter.count == 1)  // ONE split-refresh lookup for the thread, not two
    let row = try #require(try await rollup(db, account: "x", thread: "t1"))
    #expect(row.category == "social")  // still correctly reflects the LATEST label state
    #expect(row.splitKey == "social")
}
