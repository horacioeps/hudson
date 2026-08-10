import Foundation
import GmailKit
import Store

/// What one flush pass accomplished.
public struct FlushReport: Sendable, Equatable {
    public var flushed = 0
    public var retired = 0
    public var dropped = 0

    /// Empty report — also what a coalesced (second concurrent) call returns.
    public init(flushed: Int = 0, retired: Int = 0, dropped: Int = 0) {
        self.flushed = flushed
        self.retired = retired
        self.dropped = dropped
    }
}

/// Drains the local `mutation_queue` to Gmail and retires the optimistic
/// overlay ONLY after the echo lands (spec §5 / architecture M3) — the
/// convergence core of instant triage: triage must never lose an action and
/// must never flicker (the row snapping back to its pre-triage state before
/// Gmail's own confirmation has actually landed).
///
/// **Convergence invariants** (traced by every call site below):
/// 1. **Never lost.** A mutation leaves the queue only two ways: `retire`,
///    gated on the account's history cursor actually having reached the
///    echo (see #3), or a terminal-failure `drop` immediately followed by a
///    truth re-fetch (see `reconvergeMessage`). A transient failure (rate
///    limit / 5xx / network / auth) touches nothing — `claimPendingBatch` is
///    a read, not a claim-and-lock, so an un-sent row simply stays `pending`
///    for the next pass.
/// 2. **Never double-sent.** `flushOnce()` is single-flight (`flushInFlight`
///    guard below, identical in shape to `SyncEngine.syncOnce`'s), so within
///    one flusher only one send of a given row is ever in the air. A crash
///    between a successful API call and the follow-up `markInFlight` write
///    is the one acknowledged gap (see `send`'s doc comment) — label
///    add/remove is idempotent on Gmail's side, so a resend there is inert,
///    not corrupting.
/// 3. **Overlay never retires before the echo.** `retireConfirmedMutations`
///    (Store, Task 3) only deletes `in_flight` rows whose
///    `expected_history_id` is <= the account's cursor, and that cursor only
///    advances once the history poller has actually observed the event —
///    never on the strength of a 2xx response alone.
/// 4. **Batch ceiling is late-but-safe, never early.** `batchModify` answers
///    204 with no historyId, so its gate comes from a follow-up
///    `getProfile()` call: Gmail's profile historyId always reflects
///    everything already applied by the time it answers, so it's >= the
///    batch's true effect. The gate may therefore retire a beat later than
///    the tightest possible bound (harmless — the overlay just persists a
///    little longer) but can never retire early (which would flicker the
///    row back before the real echo).
public actor MutationFlusher {
    private let api: any GmailAPI
    private let database: HudsonDatabase
    private let account: String
    /// Bounded per-pass claim size: comfortably under Gmail's batchModify
    /// 1000-id cap while still draining a normal triage burst in one pass.
    /// Anything left over waits for the next signal or poll tick — bounded
    /// passes over an unbounded drain loop mirrors `SyncEngine.syncOnce`'s
    /// own `maxBackfillPages` choice, for the same reason (a single pass
    /// must not be able to run unboundedly long).
    private let claimLimit = 500
    private var flushInFlight = false
    private let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    /// Wires the flusher to one account's API client and store.
    public init(api: any GmailAPI, database: HudsonDatabase, account: String) {
        self.api = api
        self.database = database
        self.account = account
        var continuation: AsyncStream<Void>.Continuation!
        self.signals = AsyncStream { continuation = $0 }
        self.signalContinuation = continuation
    }

    /// Wakes the loop started by `start()`. Call this right after enqueuing
    /// a mutation so triage converges in well under a poll tick instead of
    /// waiting for the next timer (spec §5: <5ms). `nonisolated` and
    /// synchronous on purpose — an enqueue site should never need an actor
    /// hop just to nudge the flusher; `AsyncStream.Continuation.yield` is
    /// `Sendable` and safe to call from any thread.
    public nonisolated func wake() {
        signalContinuation.yield()
    }

    /// Runs `flushOnce()` every time `wake()` fires, until the signal stream
    /// ends. Best-effort: a failed pass is swallowed here — it simply leaves
    /// work for the next signal (or the next scheduled sync) to pick up.
    /// Callers that need to observe failures directly should call
    /// `flushOnce()` themselves instead of driving it through this loop.
    public func start() async {
        for await _ in signals {
            _ = try? await flushOnce()
        }
    }

    /// Drains one claimed batch of pending mutations to Gmail. Single-flight
    /// — a second concurrent call while one is already running coalesces to
    /// an empty report rather than claiming (and so risking double-sending)
    /// the same rows.
    ///
    /// Per pass: claim pending rows → group by identical (add,remove) label
    /// set (batchModify for >1 message, modify for a singleton) → mark sent
    /// rows in_flight with the echo's historyId → retire whatever the
    /// account cursor has now caught up to. Retirement always runs, even
    /// when a send fails partway through: confirming an EARLIER pass's
    /// already-landed echo is independent of this pass's own send outcome
    /// and must not be held hostage by it.
    public func flushOnce() async throws -> FlushReport {
        guard !flushInFlight else { return FlushReport() }
        flushInFlight = true
        defer { flushInFlight = false }

        var report = FlushReport()
        let claimed = try await database.claimPendingBatch(account: account, limit: claimLimit)

        var passError: Error?
        for group in Self.sendGroups(from: claimed) {
            do {
                try await send(group, into: &report)
            } catch let error as GmailError where Self.isTerminal(error) {
                // A 4xx that will never succeed on retry: the intent is
                // dropped (never re-sent) and truth is re-fetched per
                // message instead of guessing an inverse op locally.
                try await reconverge(group, into: &report)
            } catch {
                // Transient (rateLimited/server/network/auth) or an
                // unexpected error: stop attempting further sends this pass
                // — Gmail is likely unhappy across the board, not just for
                // this one message — but still let the unconditional retire
                // below run before this is rethrown.
                passError = error
                break
            }
        }

        report.retired = try await database.retireConfirmedMutations(account: account)
        if let passError { throw passError }
        return report
    }

    // MARK: - Send

    /// One unit of work: every message here needs the exact same
    /// (addLabelIDs, removeLabelIDs) applied, so it batches together.
    private struct SendGroup {
        let messageIDs: [String]
        let addLabelIDs: [String]
        let removeLabelIDs: [String]
        let mutationIDs: [Int64]
    }

    /// Combines each message's pending label deltas into one change (a
    /// message can have both an add and a remove pending at once — e.g.
    /// move from one label to another), then groups messages that need the
    /// IDENTICAL resulting change together: that (add,remove) key is what
    /// spec §5 batches on. Order is preserved (first-seen key order,
    /// first-seen message order within a key) purely for deterministic,
    /// easy-to-reason-about behavior — Gmail's API has no ordering
    /// requirement of its own here.
    private static func sendGroups(from mutations: [PendingMutation]) -> [SendGroup] {
        struct MessageChange { var add: [String] = []; var remove: [String] = []; var ids: [Int64] = [] }
        var perMessage: [String: MessageChange] = [:]
        var messageOrder: [String] = []
        for mutation in mutations {
            if perMessage[mutation.messageID] == nil {
                perMessage[mutation.messageID] = MessageChange()
                messageOrder.append(mutation.messageID)
            }
            switch mutation.op {
            case .add: perMessage[mutation.messageID]!.add.append(mutation.labelID)
            case .remove: perMessage[mutation.messageID]!.remove.append(mutation.labelID)
            }
            perMessage[mutation.messageID]!.ids.append(mutation.id)
        }

        struct Key: Hashable { let add: [String]; let remove: [String] }
        var messageIDsByKey: [Key: [String]] = [:]
        var keyOrder: [Key] = []
        for messageID in messageOrder {
            let change = perMessage[messageID]!
            let key = Key(add: change.add.sorted(), remove: change.remove.sorted())
            if messageIDsByKey[key] == nil { keyOrder.append(key) }
            messageIDsByKey[key, default: []].append(messageID)
        }

        return keyOrder.map { key in
            let messageIDs = messageIDsByKey[key]!
            return SendGroup(
                messageIDs: messageIDs, addLabelIDs: key.add, removeLabelIDs: key.remove,
                mutationIDs: messageIDs.flatMap { perMessage[$0]!.ids })
        }
    }

    /// Sends one group and, on success, marks its mutations in_flight with
    /// the retirement-gate historyId. A crash between the API call
    /// succeeding and `markInFlight` committing would leave the row
    /// `pending`, so a later pass could re-send an already-applied change —
    /// acceptable because Gmail label add/remove is idempotent (re-adding an
    /// already-added label, or re-removing an already-removed one, is a
    /// no-op), so a resend here is inert, never corrupting.
    private func send(_ group: SendGroup, into report: inout FlushReport) async throws {
        let historyID: Int64
        if group.messageIDs.count > 1 {
            try await api.batchModify(
                ids: group.messageIDs, addLabelIDs: group.addLabelIDs,
                removeLabelIDs: group.removeLabelIDs)
            // batchModify is 204 (no historyId) — capture a ceiling via
            // getProfile instead (invariant #4 above).
            let profile = try await api.getProfile()
            guard let ceiling = Int64(profile.historyId) else {
                throw GmailError.invalidRequest(
                    status: 0, message: "getProfile returned a non-numeric historyId")
            }
            historyID = ceiling
        } else {
            let message = try await api.modify(
                id: group.messageIDs[0], addLabelIDs: group.addLabelIDs,
                removeLabelIDs: group.removeLabelIDs)
            guard let echoed = Int64(message.historyId) else {
                throw GmailError.invalidRequest(
                    status: 0, message: "modify returned a non-numeric historyId")
            }
            historyID = echoed
        }
        try await database.markInFlight(
            mutationIDs: group.mutationIDs, expectedHistoryID: historyID, account: account)
        report.flushed += group.mutationIDs.count
    }

    // MARK: - Terminal-failure reconvergence

    /// A 4xx Gmail permanently rejected (e.g. an invalid label, or a message
    /// that no longer exists) can never succeed by retrying — the mutation
    /// is dropped from the queue (never re-sent) and truth is re-fetched per
    /// message to correct whatever the optimistic overlay had assumed. This
    /// is deliberately a "never guess the inverse" reconciliation: rather
    /// than assuming the operation didn't happen and undoing it locally, we
    /// ask Gmail what's actually there.
    private func reconverge(_ group: SendGroup, into report: inout FlushReport) async throws {
        for id in group.mutationIDs {
            try await database.dropMutation(id: id, account: account)
        }
        report.dropped += group.mutationIDs.count
        for messageID in group.messageIDs {
            await reconvergeMessage(messageID)
        }
    }

    /// Best-effort per-message truth re-fetch after a drop.
    ///
    /// Fetches `format: "minimal"` — enough to correct just the label
    /// overlay (id + labelIds + historyId) — and writes it through the same
    /// labels-only, version-guarded path the history poller itself uses
    /// (`applyHistoryChanges` with a `.labels` change). This deliberately
    /// does NOT go through `applySnapshot` here: `format: "minimal"`
    /// omits headers/snippet/internalDate (Gmail API reference: minimal
    /// "does not return the email headers, body, or payload"), and
    /// `applySnapshot` unconditionally overwrites subject/from/to/snippet —
    /// feeding it a minimal-format message would blank out real, already-
    /// stored content just to correct a label. The labels-only path touches
    /// only `history_id` and `message_labels`, so nothing else can be
    /// clobbered, while still converging the overlay to server truth.
    ///
    /// If the message isn't known locally at all yet (rare: a mutation
    /// raced a concurrent tombstone, or was enqueued against a row that was
    /// never fully hydrated), a labels-only patch can't materialize it — a
    /// fuller `format: "metadata"` fetch (headers + snippet + internalDate,
    /// still no body) is used instead to build a real `applySnapshot`, the
    /// same fallback `SyncEngine.pollHistory` uses for its own unknown ids.
    ///
    /// Any failure here is swallowed: the mutation is already correctly
    /// dropped (it will never be resent), and the next history poll will
    /// converge the display on its own — this fetch only exists to close
    /// that window faster, not to guarantee it.
    private func reconvergeMessage(_ messageID: String) async {
        do {
            let message = try await api.getMessage(id: messageID, format: "minimal")
            guard let historyID = Int64(message.historyId) else { return }
            let unknownIDs = try await database.applyHistoryChanges(
                [HistoryChange(kind: .labels(
                    id: messageID, historyID: historyID, labelIDs: message.labelIds ?? []))],
                account: account)
            guard unknownIDs.contains(messageID) else { return }
            let full = try await api.getMessage(id: messageID, format: "metadata")
            if let snapshot = SnapshotMapping.snapshot(from: full) {
                _ = try await database.applySnapshot(snapshot, account: account)
            }
        } catch GmailError.invalidRequest(let status, _) where status == 404 {
            // Provably gone server-side too — tombstone rather than leave a
            // ghost row (mirrors SyncEngine.hydrateBodies's own 404 handling).
            try? await database.deleteVanishedMessage(id: messageID, account: account)
        } catch {
            Log.sync.warning("MutationFlusher: reconverge re-fetch failed after drop; next poll will correct")
        }
    }

    /// A "terminal 4xx" per spec §5 is specifically `invalidRequest` — a
    /// request Gmail permanently rejected. `auth` (401, needs re-auth),
    /// `rateLimited`, `server` (5xx), and `network` are all transient: none
    /// of them mean the mutation itself is invalid, only that this attempt
    /// to send it didn't land — leaving it pending is safe and correct.
    private static func isTerminal(_ error: GmailError) -> Bool {
        if case .invalidRequest = error { return true }
        return false
    }
}
