import Foundation
import GmailKit
import Store
import Testing
@testable import Outbox

// M5 Task 4: the send state machine — enqueue (assign Message-ID + validate
// size + undo-hold), undo cancel, and the crash-safe flush + restart dedup
// probe (spec §7.3). The load-bearing proof here is (c): a job stranded
// `in_flight` by a kill between "sent on the wire" and "recorded sent" is
// resolved by PROBING the sent mailbox for its persisted Message-ID and
// marking it sent — never blindly resent into a duplicate.

/// A scriptable `SendTransport` double: records every send, and can be
/// scripted to fail a send or to answer the restart dedup probe (per
/// Message-ID hit, or a blanket miss). Mirrors `ScriptedGmail`'s posture
/// from the SyncEngine tests — an actor recording calls for assertions.
actor RecordingSendTransport: SendTransport {
    /// SentMessage returned by `sendRawMessage` on success.
    var sendResult = SentMessage(id: "sent-server-1", threadId: "t1", labelIds: ["SENT"])
    /// When set, `sendRawMessage` throws this instead of succeeding.
    var sendError: Error?
    /// Per-Message-ID probe hits (rfc822 Message-ID → Gmail message id).
    var probeHitsByID: [String: String] = [:]
    /// When set, `findSentMessageID` throws this instead of answering.
    var probeError: Error?

    private(set) var sentMIMEs: [Data] = []
    private(set) var sentThreadIDs: [String?] = []
    private(set) var probedIDs: [String] = []

    var sendCount: Int { sentMIMEs.count }

    func setSendError(_ error: Error?) { sendError = error }
    func setProbeError(_ error: Error?) { probeError = error }
    func setProbeHit(_ gmailID: String, forRFC822 id: String) { probeHitsByID[id] = gmailID }

    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage {
        sentMIMEs.append(rawMIME)
        sentThreadIDs.append(threadID)
        if let sendError { throw sendError }
        return sendResult
    }

    func findSentMessageID(rfc822MessageID: String) async throws -> String? {
        probedIDs.append(rfc822MessageID)
        if let probeError { throw probeError }
        return probeHitsByID[rfc822MessageID]
    }
}

private let account = "me@hudson.test"

private func plainMessage(subject: String = "Hello") -> OutboxMessage {
    OutboxMessage(
        from: "me@hudson.test", to: ["you@example.com"], subject: subject,
        bodyText: "Body of the message.")
}

@Test func enqueueThenFlushMarksSent() async throws {
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    // undoHold 0 so the job is immediately claimable at now.
    let jobID = try await service.enqueue(
        plainMessage(), undoHold: .zero, now: 1_000)
    let sent = try await service.flushOnce(now: 1_000)

    #expect(sent == 1)
    #expect(await transport.sendCount == 1)
    let jobs = try await database.inFlightSendJobs(account: account)
    #expect(jobs.isEmpty)  // no longer in_flight — it's terminal `sent`
    // The claim worklist is now empty (job is terminal), and its recorded
    // Gmail id is the send response's id.
    let stillClaimable = try await database.claimSendable(account: account, now: 1_000)
    #expect(stillClaimable.isEmpty)
    _ = jobID
}

@Test func undoCancelsWhileHeldButNotOnceInFlight() async throws {
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    // A 15s hold: at now=1_000 the job is held until 16_000.
    let jobID = try await service.enqueue(
        plainMessage(), undoHold: .seconds(15), now: 1_000)

    // Within the hold window: undo succeeds and the job is gone.
    #expect(try await service.cancel(jobID: jobID, now: 2_000) == true)
    #expect(try await database.claimSendable(account: account, now: 999_999).isEmpty)

    // Now prove the *in_flight* guard specifically — not merely an elapsed
    // hold. Both jobs below are enqueued with a 15s hold at now=3_000
    // (hold_until = 18_000), and both are cancel-probed at now=4_000, well
    // WITHIN that window. The only difference is state: the control job stays
    // pending, `heldJob` is driven `in_flight`.
    let controlID = try await service.enqueue(
        plainMessage(subject: "Control"), undoHold: .seconds(15), now: 3_000)
    let heldJobID = try await service.enqueue(
        plainMessage(subject: "Second"), undoHold: .seconds(15), now: 3_000)
    try await database.markSendInFlight(id: heldJobID, account: account)

    // The pending control IS cancellable at now=4_000 — so the hold window is
    // genuinely still open at the cancel instant. This is what makes the next
    // assertion meaningful: an identical still-held job cannot be undone once
    // it is `in_flight`, and state is the ONLY variable that differs.
    #expect(try await service.cancel(jobID: heldJobID, now: 4_000) == false)
    #expect(try await service.cancel(jobID: controlID, now: 4_000) == true)
}

@Test func killBetweenSendAndRecordIsResolvedByProbeNotResent() async throws {
    // The core dedup proof (spec §7.3): a job left `in_flight` (its
    // in_flight transition committed, but the process died before recording
    // the send) whose Message-ID the probe FINDS in Sent must be marked
    // sent, and MUST NOT be resent.
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let jobID = try await service.enqueue(plainMessage(), undoHold: .zero, now: 1_000)
    // Simulate the crash: commit in_flight, then "die" before the send is
    // recorded. The job is now a stranded in_flight of unknown outcome.
    try await database.markSendInFlight(id: jobID, account: account)
    let stranded = try await database.inFlightSendJobs(account: account)
    #expect(stranded.count == 1)
    // The send actually DID land server-side — script the probe to find it.
    await transport.setProbeHit("gmail-abc", forRFC822: stranded[0].rfc822MessageID)

    let sent = try await service.flushOnce(now: 2_000)

    #expect(sent == 1)                       // confirmed sent — but via probe, not a fresh send
    #expect(await transport.sendCount == 0)  // NEVER resent — the whole point
    #expect(try await database.inFlightSendJobs(account: account).isEmpty)  // now terminal `sent`
}

@Test func ambiguousProbeMissLeavesInFlightAndDoesNotResend() async throws {
    // A fast probe MISS is not proof of non-delivery (search indexing lags):
    // the job stays `in_flight` for re-probing next flush, and is never
    // resent.
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let jobID = try await service.enqueue(plainMessage(), undoHold: .zero, now: 1_000)
    try await database.markSendInFlight(id: jobID, account: account)

    // No probe hit scripted → miss.
    let sent = try await service.flushOnce(now: 2_000)

    #expect(sent == 0)
    #expect(await transport.sendCount == 0)  // ambiguous → wait, do NOT resend
    #expect(try await database.inFlightSendJobs(account: account).count == 1)  // still in_flight
    #expect(await transport.probedIDs.count == 1)  // it WAS re-probed
}

private struct TransportBoom: Error {}

@Test func sendFailureLeavesInFlightAndNeverResendsAcrossTheFailure() async throws {
    // Spec §7.3's crash-safety property at the send-error boundary: when the
    // wire call throws, the job is ALREADY committed `in_flight`, so the pass
    // must leave it there (not pending, not failed) and stop — the next
    // flush's probe path is the ONLY thing allowed to decide its fate, and it
    // must never resend across the failure.
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let jobID = try await service.enqueue(plainMessage(), undoHold: .zero, now: 1_000)
    await transport.setSendError(TransportBoom())

    // First flush: the send is attempted (sendCount == 1) and throws. Nothing
    // is confirmed, and the job is stranded `in_flight`.
    let firstSent = try await service.flushOnce(now: 1_000)
    #expect(firstSent == 0)
    #expect(await transport.sendCount == 1)  // the wire WAS hit, exactly once
    let stranded = try await database.inFlightSendJobs(account: account)
    #expect(stranded.count == 1)  // left in_flight — not pending, not failed
    // Not pending/held either: it is not on the claim worklist.
    #expect(try await database.claimSendable(account: account, now: 999_999).isEmpty)

    // The failed wire call actually DID land server-side (the classic
    // kill-after-send ambiguity). Clear the error and script the probe to find
    // it. The second flush must resolve it via the probe, NOT a fresh send.
    await transport.setSendError(nil)
    await transport.setProbeHit("gmail-recovered", forRFC822: stranded[0].rfc822MessageID)

    let secondSent = try await service.flushOnce(now: 2_000)
    #expect(secondSent == 1)                       // confirmed sent — via probe
    #expect(await transport.sendCount == 1)        // STILL 1: never resent across the failure
    #expect(try await database.inFlightSendJobs(account: account).isEmpty)  // terminal `sent`
    _ = jobID
}

@Test func probeErrorRethrowsAndLeavesJobInFlight() async throws {
    // A probe that itself throws (Gmail unreachable) is not a non-delivery
    // signal — §7.3 forbids guessing. `flushOnce` must rethrow and leave the
    // job `in_flight` for the next pass, never resend.
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let jobID = try await service.enqueue(plainMessage(), undoHold: .zero, now: 1_000)
    try await database.markSendInFlight(id: jobID, account: account)
    await transport.setProbeError(TransportBoom())

    await #expect(throws: TransportBoom.self) {
        _ = try await service.flushOnce(now: 2_000)
    }
    // Untouched: still in_flight, never resent.
    #expect(try await database.inFlightSendJobs(account: account).count == 1)
    #expect(await transport.sendCount == 0)
}

@Test func enqueueRejectsOversizedMessageAtEnqueueTime() async throws {
    // Size validation happens at ENQUEUE, never at fire time (spec §7.1):
    // an oversized attachment throws from `enqueue`, before any job row is
    // ever written.
    let database = try HudsonDatabase.inMemory()
    let transport = RecordingSendTransport()
    let service = SendService(api: transport, database: database, account: account)

    let huge = Attachment(
        filename: "big.bin", mimeType: "application/octet-stream",
        data: Data(count: MimeBuilder.maxEncodedBytes))  // > cap after base64
    let message = OutboxMessage(
        from: "me@hudson.test", to: ["you@example.com"], subject: "Big",
        bodyText: "x", attachments: [huge])

    await #expect(throws: OutboxError.self) {
        _ = try await service.enqueue(message, undoHold: .zero, now: 1_000)
    }
    // Nothing was persisted.
    #expect(try await database.claimSendable(account: account, now: 999_999).isEmpty)
}
