import Foundation
import GmailKit
import Store

/// The slice of GmailClient SyncEngine needs — a seam so tests script the
/// server instead of mocking HTTP.
public protocol GmailAPI: Sendable {
    func getProfile() async throws -> Profile
    func listMessages(pageToken: String?, maxResults: Int) async throws -> MessageListPage
    func getMessage(id: String, format: String) async throws -> GmailMessage
    func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage
    func listLabels() async throws -> [GmailLabel]
}

extension GmailClient: GmailAPI {}

/// What one sync pass accomplished.
public struct SyncReport: Sendable, Equatable {
    public var backfilledThisPass = 0
    public var eventsApplied = 0
    public var bodiesHydrated = 0
    public var backfillComplete = false

    /// Empty report — also what a coalesced (second concurrent) pass returns.
    public init() {}
}

/// Orchestrates backfill, history polling, and body hydration for one account
/// (spec §4). Single-flight: one pass in flight; concurrent calls coalesce to
/// an empty report (§4.6). All cross-pass state lives in SQLite.
public actor SyncEngine {
    private let api: any GmailAPI
    private let database: HudsonDatabase
    private let account: String
    private let pageSize: Int
    private let hydrationBatch: Int
    private let prefetchWindowDays: Int
    private let now: @Sendable () -> Date
    private var passInFlight = false

    /// Wires the engine to one account's API client and store.
    public init(
        api: any GmailAPI, database: HudsonDatabase, account: String,
        pageSize: Int = 100, hydrationBatch: Int = 25, prefetchWindowDays: Int = 90,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.database = database
        self.account = account
        self.pageSize = pageSize
        self.hydrationBatch = hydrationBatch
        self.prefetchWindowDays = prefetchWindowDays
        self.now = now
    }

    /// One bounded pass: ensure cursor → apply history → up to
    /// `maxBackfillPages` backfill pages → one hydration batch.
    public func syncOnce(maxBackfillPages: Int = 5) async throws -> SyncReport {
        guard !passInFlight else { return SyncReport() }
        passInFlight = true
        defer { passInFlight = false }

        var report = SyncReport()
        try await ensureCursor()
        report.eventsApplied = try await pollHistory()
        try await backfill(maxPages: maxBackfillPages, into: &report)
        report.bodiesHydrated = try await hydrateBodies()
        return report
    }

    // MARK: - Cursor

    /// Records profile.historyId BEFORE the first list call (spec §4.1), so
    /// incremental sync covers everything that changes mid-backfill.
    private func ensureCursor() async throws {
        guard let record = try await database.account(email: account) else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        guard record.historyCursor == nil else { return }
        let profile = try await api.getProfile()
        // A silently-seeded 0 would make Task 10's incremental sync believe
        // history starts at the very beginning — load-bearing, so fail loudly
        // instead of guessing.
        guard let cursor = Int64(profile.historyId) else {
            throw GmailError.invalidRequest(
                status: 0, message: "profile.historyId is not a parsable integer")
        }
        _ = try await database.applyHistory([], newCursor: cursor, account: account)
    }

    // MARK: - History (M2: applied via Store; expiry fallback restarts backfill)

    /// Polls history.list and applies changes in order. Returns events applied.
    /// Task 10 extends this; the Task 9 skeleton returns 0 without polling.
    private func pollHistory() async throws -> Int { 0 }

    // MARK: - Backfill

    private func backfill(maxPages: Int, into report: inout SyncReport) async throws {
        var record = try await requireAccount()
        if record.backfillState == "complete" {
            report.backfillComplete = true
            return
        }
        for _ in 0..<maxPages {
            let page = try await api.listMessages(
                pageToken: record.backfillPageToken, maxResults: pageSize)
            var added = 0
            for ref in page.messages ?? [] {
                do {
                    let message = try await api.getMessage(id: ref.id, format: "metadata")
                    guard let snapshot = SnapshotMapping.snapshot(from: message) else { continue }
                    if try await database.applySnapshot(snapshot, account: account) == .applied {
                        added += 1
                    }
                } catch let error as GmailError {
                    // One bad message must not abort the pass — the page token
                    // still needs to persist so backfill keeps advancing.
                    logSkippedBackfillMessage(error)
                }
            }
            report.backfilledThisPass += added
            let finished = page.nextPageToken == nil
            try await database.updateBackfill(
                email: account,
                state: finished ? "complete" : "listing",
                pageToken: page.nextPageToken,
                addedCount: added)
            if finished {
                report.backfillComplete = true
                return
            }
            record = try await requireAccount()
        }
    }

    /// A message that vanished between `messages.list` and `messages.get`
    /// (404) is expected and silent — it's simply gone, nothing to persist.
    /// No standalone Store API tombstones a single id without also advancing
    /// the history cursor (that coupling belongs to `applyHistory`, not
    /// backfill), so we just skip rather than misuse it here. Any other
    /// GmailError also skips the message (never id/content, spec §9.1) so one
    /// bad message can't stall the whole page.
    private func logSkippedBackfillMessage(_ error: GmailError) {
        switch error {
        case .invalidRequest(let status, _) where status == 404:
            return
        case .invalidRequest(let status, _):
            Log.sync.warning("backfill getMessage skipped: invalidRequest status=\(status, privacy: .public)")
        case .server(let status):
            Log.sync.warning("backfill getMessage skipped: server status=\(status, privacy: .public)")
        case .rateLimited:
            Log.sync.warning("backfill getMessage skipped: rateLimited")
        case .network:
            Log.sync.warning("backfill getMessage skipped: network")
        case .auth:
            Log.sync.warning("backfill getMessage skipped: auth")
        }
    }

    // MARK: - Body hydration (newest-first within the prefetch window)

    private func hydrateBodies() async throws -> Int {
        let windowStart = Int64(
            now().addingTimeInterval(-Double(prefetchWindowDays) * 86_400)
                .timeIntervalSince1970 * 1_000)
        let ids = try await database.messageIDsNeedingBodies(
            account: account, since: windowStart, limit: hydrationBatch)
        var hydrated = 0
        for id in ids {
            let message = try await api.getMessage(id: id, format: "full")
            let content = message.extractContent()
            try await database.saveBody(
                messageID: id, account: account,
                body: Sanitizer.sanitize(html: content.htmlData, plainText: content.plainText))
            hydrated += 1
        }
        return hydrated
    }

    private func requireAccount() async throws -> AccountRecord {
        guard let record = try await database.account(email: account) else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        return record
    }
}
