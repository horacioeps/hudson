import Foundation
import GmailKit
import Store

/// The subset of `GmailClient` the send state machine drives, expressed as a
/// protocol so tests inject a scriptable double (mirrors how `SyncEngine`
/// takes `any GmailAPI`). Exactly the two calls §7.3's dedup protocol needs:
/// the send itself, and the restart probe that searches Sent for a job's
/// persisted RFC `Message-ID`.
public protocol SendTransport: Sendable {
    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage
    func findSentMessageID(rfc822MessageID: String) async throws -> String?
}

/// `GmailClient` already implements both calls (GmailKit's `SendEndpoints`),
/// so the conformance is empty — it just names the real transport as one.
extension GmailClient: SendTransport {}

/// Drives one account's `send_jobs` queue through the durability state
/// machine `pending/held → in_flight → sent` (spec §7.3), and — the reason
/// this whole subsystem exists — resolves jobs stranded `in_flight` by a
/// crash WITHOUT ever risking a duplicate send, because Gmail's API has no
/// idempotency token so dedup is our job.
///
/// An `actor` for the same reason `MutationFlusher` is one: it owns
/// network-driven mutable progress (the single-flight guard) and must
/// serialize its own flush passes. Store access is through the existing
/// `async` `HudsonDatabase` APIs — no off-actor writer access.
///
/// **The dedup invariant, traced through the code below:**
/// 1. **Message-ID at enqueue.** `enqueue` mints a UUID-based RFC 5322
///    `Message-ID`, bakes it into the MIME, AND persists it on the job row.
///    That one identifier is what both the sent message header and the
///    restart probe key on — so a message sent before a crash can be
///    RECOGNIZED after it.
/// 2. **`in_flight` committed before the wire.** `flushOnce` awaits
///    `markSendInFlight` (a real SQLite commit) BEFORE calling
///    `sendRawMessage`. So any job the network call might have delivered is
///    already, durably, `in_flight` — never still `pending` where a naive
///    retry would resend it.
/// 3. **Probe, never blind-resend, on restart.** For every `in_flight` job
///    of unknown outcome, `flushOnce` probes Sent for its Message-ID first.
///    A HIT → mark sent. A MISS is NOT proof of non-delivery (Gmail's search
///    index lags the send), so the job is LEFT `in_flight` to be re-probed
///    next pass — deliberately never resent, because a fast miss right after
///    a crash is exactly when a blind resend would double-deliver.
public actor SendService {
    private let api: any SendTransport
    private let database: HudsonDatabase
    private let account: String
    /// Single-flight guard (identical in intent to `MutationFlusher`'s):
    /// two overlapping `flushOnce` calls could otherwise interleave at an
    /// `await` and both try to drive the same job, so a second concurrent
    /// call coalesces to a no-op (returns 0) rather than racing.
    private var flushInFlight = false

    public init(api: any SendTransport, database: HudsonDatabase, account: String) {
        self.api = api
        self.database = database
        self.account = account
    }

    /// Composes a message into a durable send job. In one shot, and BEFORE
    /// any network exists in the picture: mint the UUID `Message-ID` (§7.3),
    /// build the RFC 5322 MIME (which also SIZE-VALIDATES here at enqueue,
    /// never at fire time — spec §7.1, so an oversized attachment fails while
    /// the user is still composing), compute the undo-send hold window, and
    /// persist. Returns the job id — the handle `cancel` (undo-send) needs.
    ///
    /// The Message-ID is persisted on the row (`enqueueSend`'s
    /// `rfc822MessageID`) precisely because the restart probe searches Gmail
    /// for it: the header inside `rawMIME` and the column MUST be the same
    /// string, which is why both are derived from the single `messageID`
    /// built here.
    public func enqueue(
        _ message: OutboxMessage,
        undoHold: Duration = .seconds(15),
        now: Int64
    ) async throws -> Int64 {
        let messageID = Self.makeMessageID(senderAddress: message.from)
        // Real wall-clock `Date` for the outgoing `Date:` header — this is a
        // genuine send, not a golden-file build, so nondeterminism here is
        // correct (unlike `MimeBuilderTests`, which pins the date). `build`
        // throws `OutboxError.tooLarge` if the message exceeds the cap; that
        // propagates out of `enqueue` with no row ever written.
        let rawMIME = try MimeBuilder.build(message, messageID: messageID, date: Date())
        let holdUntil = now + Self.milliseconds(undoHold)
        return try await database.enqueueSend(
            account: account, rfc822MessageID: messageID, threadID: message.threadID,
            rawMIME: rawMIME, holdUntil: holdUntil, now: now)
    }

    /// Undo-send: cancels a job while it is still within its hold window and
    /// has not gone `in_flight`. Delegates the whole precondition to
    /// `cancelSend` (which refuses once the send may be in motion) and
    /// returns whether it actually cancelled.
    public func cancel(jobID: Int64, now: Int64) async throws -> Bool {
        try await database.cancelSend(id: jobID, account: account, now: now)
    }

    /// One flush pass: first resolve any crash-stranded `in_flight` jobs by
    /// probe (never by resend), then send everything past its undo-hold.
    /// Returns the number of jobs newly confirmed sent this pass (whether
    /// via a fresh send or via a probe that recognized an already-delivered
    /// one). Single-flight — a concurrent second call coalesces to 0.
    @discardableResult
    public func flushOnce(now: Int64) async throws -> Int {
        guard !flushInFlight else { return 0 }
        flushInFlight = true
        defer { flushInFlight = false }

        var confirmed = 0
        confirmed += try await resolveStrandedInFlight()
        confirmed += try await sendClaimable(now: now)
        return confirmed
    }

    // MARK: - Restart dedup probe (invariant #3)

    /// For each job stranded `in_flight` (its `in_flight` transition
    /// committed, its outcome unknown — the kill-between-send-and-record
    /// window), probe Sent for its persisted Message-ID:
    /// - HIT → the message reached Gmail; mark it `sent`. NOT resent.
    /// - MISS → ambiguous (search indexing lags a real send), so LEAVE it
    ///   `in_flight` and move on; the next flush re-probes. Deliberately
    ///   never resent — a blind resend on a fast miss is the one way this
    ///   protocol could double-deliver.
    ///
    /// A probe that itself throws (Gmail unreachable) is left for the next
    /// pass by rethrowing: we simply don't yet know, and guessing is exactly
    /// what §7.3 forbids.
    private func resolveStrandedInFlight() async throws -> Int {
        var confirmed = 0
        for job in try await database.inFlightSendJobs(account: account) {
            if let sentGmailID = try await api.findSentMessageID(
                rfc822MessageID: job.rfc822MessageID) {
                let recorded = try await database.markSent(
                    id: job.id, account: account, sentMessageID: sentGmailID)
                if recorded { confirmed += 1 }
            }
            // else: ambiguous miss — leave `in_flight`, re-probe next pass.
        }
        return confirmed
    }

    // MARK: - Send (invariant #2)

    /// Sends every job past its undo-hold. Per job, in this exact order:
    /// commit `in_flight` (BEFORE the wire, §7.3) → `sendRawMessage` →
    /// record the returned Gmail id via `markSent`.
    ///
    /// If a send throws, the job is ALREADY durably `in_flight`, so we stop
    /// the pass rather than resend or guess: the next flush's probe path
    /// (`resolveStrandedInFlight`) is the one place allowed to decide that
    /// job's fate, and it will never resend on an ambiguous outcome. Every
    /// job not yet reached stays `pending` and is retried cleanly next pass —
    /// so a single transient failure strands at most the one job whose wire
    /// call we had already committed to.
    private func sendClaimable(now: Int64) async throws -> Int {
        var confirmed = 0
        for job in try await database.claimSendable(account: account, now: now) {
            try await database.markSendInFlight(id: job.id, account: account)
            let result: SentMessage
            do {
                result = try await api.sendRawMessage(job.rawMIME, threadID: job.threadID)
            } catch {
                // Unknown outcome now committed as `in_flight`: hand it to the
                // probe path next pass and stop sending this pass.
                break
            }
            let recorded = try await database.markSent(
                id: job.id, account: account, sentMessageID: result.id)
            if recorded { confirmed += 1 }
        }
        return confirmed
    }

    // MARK: - Helpers

    /// Mints the UUID-based RFC 5322 `Message-ID` (§7.3). The domain is the
    /// sender's own when parseable (better deliverability and a truthful
    /// header), falling back to `hudson.local` — the dedup protocol only
    /// requires the SAME value land in both the MIME header and the job row,
    /// which it does by construction (one call, one string).
    static func makeMessageID(senderAddress: String) -> String {
        let domain = senderDomain(from: senderAddress) ?? "hudson.local"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    /// Extracts the domain from a `From` value that may be a bare address
    /// (`a@b.com`) or a display-name form (`Name <a@b.com>`). Returns nil if
    /// there's no usable `@domain`, so the caller falls back to
    /// `hudson.local`.
    private static func senderDomain(from address: String) -> String? {
        guard let atIndex = address.lastIndex(of: "@") else { return nil }
        let tail = address[address.index(after: atIndex)...]
        let domain = tail.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        return domain.isEmpty ? nil : domain
    }

    /// Whole milliseconds in a `Duration` — the unit `hold_until` is stored
    /// in (ms since epoch). Sub-millisecond precision is irrelevant to a
    /// human undo-send window, so it's simply truncated.
    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
