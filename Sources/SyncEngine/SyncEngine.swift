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
    func modify(id: String, addLabelIDs: [String], removeLabelIDs: [String]) async throws -> GmailMessage
    func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws
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
    /// Set by `pollHistory()` when this pass hit a 404 expiry, so `syncOnce()`
    /// can defer the resulting re-list to the next pass (see its doc comment).
    private var historyExpiredThisPass = false

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
        // A just-expired cursor already reset backfill to "pending" (below);
        // running backfill synchronously in this same pass would immediately
        // re-list and could re-flip it straight back to "complete" before the
        // caller ever observes the reset — the re-list is scheduled, not
        // performed inline, so it gets its own pass (and its own
        // `maxBackfillPages` budget) like any other backfill progress.
        if !historyExpiredThisPass {
            try await backfill(maxPages: maxBackfillPages, into: &report)
        }
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

    /// Polls history.list from the stored cursor and applies each page's
    /// changes in order, then advances the cursor exactly ONCE, after the
    /// last page (spec §4.3). Unknown ids get hydrated afterwards. A 404
    /// from `listHistory` (and *only* from `listHistory` — see below) means
    /// the cursor expired: M2's fallback resets backfill and re-lists (M3
    /// brings the cheaper format=minimal reconciliation).
    ///
    /// The cursor is deliberately NOT committed per page: Gmail reports the
    /// *current mailbox* historyId on every page of a poll, not "as of this
    /// page," so a per-page commit would jump the cursor to its final value
    /// on page 1 while pages 2..N are still unapplied — a crash between
    /// pages would then silently lose them (M2-review-deferred crash-window
    /// fix). Instead each page's changes are applied via
    /// `applyHistoryChanges` (cursor untouched) and the last page's
    /// historyId is committed via `advanceCursor` only once pagination
    /// finishes. A crash anywhere in the loop leaves the cursor at its old
    /// value, so the next pass's re-poll simply re-applies from there —
    /// safe because of the §4.2 version guard.
    private func pollHistory() async throws -> Int {
        historyExpiredThisPass = false
        guard let cursor = try await requireAccount().historyCursor else { return 0 }
        var applied = 0
        var pageToken: String?
        // Fixed for the whole pagination loop: a Gmail page token continues
        // the listing it was created by, so pairing it with a startHistoryId
        // that changed between pages is undefined. Only pageToken advances
        // between pages.
        let start = String(cursor)
        // Tracks the most recently seen page historyId, committed once via
        // `advanceCursor` after the loop — see the doc comment above.
        var lastHistoryID = cursor
        repeat {
            let page: HistoryPage
            do {
                page = try await api.listHistory(startHistoryID: start, pageToken: pageToken)
            } catch GmailError.invalidRequest(let status, _) where status == 404 {
                // Cursor expired (spec §4.3). Blunt-but-correct M2 fallback:
                // fresh cursor, full re-list; the §4.2 guard makes re-listing
                // safe. Scoped to `listHistory` alone — a 404 from the
                // hydration `getMessage` below is a different, unrelated
                // event (a message that vanished, not an expired cursor) and
                // must never trigger this branch.
                Log.transport.warning("History cursor expired; falling back to full re-list.")
                historyExpiredThisPass = true
                let profile = try await api.getProfile()
                _ = try await database.applyHistory(
                    [], newCursor: Int64(profile.historyId) ?? 0, account: account)
                try await database.updateBackfill(
                    email: account, state: "pending", pageToken: nil, addedCount: 0)
                return 0
            }
            let changes = HistoryMapping.changes(from: page.history ?? [])
            lastHistoryID = page.historyId.flatMap(Int64.init) ?? lastHistoryID
            let unknownIDs = try await database.applyHistoryChanges(changes, account: account)
            applied += changes.count
            for id in unknownIDs {
                do {
                    let message = try await api.getMessage(id: id, format: "metadata")
                    if let snapshot = SnapshotMapping.snapshot(from: message) {
                        _ = try await database.applySnapshot(snapshot, account: account)
                    }
                } catch GmailError.invalidRequest(let status, _) where status == 404 {
                    // The message vanished between the history event and
                    // this hydration get — expected and silent (spec §9.1:
                    // no id/content in logs), the same treatment backfill
                    // gives a per-message 404 (see `logSkippedMessage`
                    // below). Any other error still propagates: the cursor
                    // hasn't been committed yet (only `advanceCursor` after
                    // the loop does that), so a real failure here simply
                    // leaves it at its old value — safe to retry from.
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        try await database.advanceCursor(to: lastHistoryID, account: account)
        return applied
    }

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
            var snapshots: [MessageSnapshot] = []
            for ref in page.messages ?? [] {
                do {
                    let message = try await api.getMessage(id: ref.id, format: "metadata")
                    guard let snapshot = SnapshotMapping.snapshot(from: message) else { continue }
                    snapshots.append(snapshot)
                } catch let error as GmailError {
                    // One bad message must not abort the pass — the page token
                    // still needs to persist so backfill keeps advancing.
                    logSkippedMessage(error, phase: "backfill")
                }
            }
            // One commit per page instead of per message: the load-bearing
            // control against the SwiftUI ValueObservation storm during the
            // ~6h backfill (architecture M3). Each message is still guarded
            // by its own SAVEPOINT inside `applySnapshots`.
            let added = try await database.applySnapshots(snapshots, account: account)
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

    /// A message that vanished between `messages.list` (or a history poll)
    /// and a follow-up `messages.get` (404) is expected and silent — it's
    /// simply gone, nothing to persist. No standalone Store API tombstones a
    /// single id without also advancing the history cursor (that coupling
    /// belongs to `applyHistory`, not backfill), so we just skip rather than
    /// misuse it here. Any other GmailError also skips the message (never
    /// id/content, spec §9.1) so one bad message can't stall the whole page.
    /// Shared by `backfill` and `hydrateBodies`; `hydrateBodies` handles its
    /// own 404s separately (it tombstones instead of silently skipping — see
    /// there) and only routes here for everything else. `phase` is a fixed,
    /// content-free label identifying which loop skipped the message.
    private func logSkippedMessage(_ error: GmailError, phase: String) {
        switch error {
        case .invalidRequest(let status, _) where status == 404:
            return
        case .invalidRequest(let status, _):
            Log.sync.warning("\(phase) getMessage skipped: invalidRequest status=\(status, privacy: .public)")
        case .server(let status):
            Log.sync.warning("\(phase) getMessage skipped: server status=\(status, privacy: .public)")
        case .rateLimited:
            Log.sync.warning("\(phase) getMessage skipped: rateLimited")
        case .network:
            Log.sync.warning("\(phase) getMessage skipped: network")
        case .auth:
            Log.sync.warning("\(phase) getMessage skipped: auth")
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
            do {
                let message = try await api.getMessage(id: id, format: "full")
                let content = message.extractContent()
                let attachments = message.attachments().map {
                    AttachmentMeta(
                        id: $0.attachmentID, filename: $0.filename,
                        mimeType: $0.mimeType, size: $0.size)
                }
                try await database.saveBody(
                    messageID: id, account: account,
                    body: Sanitizer.sanitize(html: content.htmlData, plainText: content.plainText),
                    attachments: attachments)
                hydrated += 1
            } catch GmailError.invalidRequest(let status, _) where status == 404 {
                // The message provably no longer exists server-side — unlike
                // backfill's silent skip (nothing was ever persisted for it),
                // this id is already sitting in the store with has_body=0, so
                // skipping alone would leave it at the head of
                // `messageIDsNeedingBodies`'s work-list forever, failing
                // every future `hudson sync` with the same 404 (e.g. a ghost
                // row left by the §4.3 expiry re-list). Tombstone + delete
                // instead so it leaves the work-list for good.
                try await database.deleteVanishedMessage(id: id, account: account)
            } catch let error as GmailError {
                // Any other failure skips just this message — never lets one
                // bad id stall the whole hydration batch.
                logSkippedMessage(error, phase: "hydrateBodies")
            }
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
