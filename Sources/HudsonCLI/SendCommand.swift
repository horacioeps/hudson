import ArgumentParser
import Foundation
import GmailKit
import Outbox
import Store
import UniformTypeIdentifiers

/// Composes and enqueues a brand-new message (spec §7 Outbox).
///
/// `--to`/`--subject` are required (no default value ⇒ ArgumentParser
/// enforces at least one occurrence); `--body` is optional because a body
/// can also arrive over stdin (`echo "hi" | hudson send --to … --subject …`)
/// — see `SendCLI.resolveBody`. `--attach` repeats for multiple files.
struct SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Compose and send a new message."
    )

    @Option(name: .customLong("to"), help: "Recipient address (repeat for multiple).")
    var to: [String]

    @Option(help: "Subject line.")
    var subject: String

    @Option(help: "Message body (plain text). Omit to read from stdin.")
    var body: String?

    @Option(name: .customLong("attach"), help: "Path to a file to attach (repeat for multiple).")
    var attach: [String] = []

    func run() async throws {
        do {
            let runtime = try await Runtime.bootstrap()
            let bodyText = try SendCLI.resolveBody(body)
            let attachments = try SendCLI.loadAttachments(attach)
            let message = buildMessage(
                from: runtime.account.email, bodyText: bodyText, attachments: attachments)
            try await SendCLI.enqueueFlushAndReport(message, runtime: runtime)
        } catch let error as GmailError {
            throw reportAndFail(error)
        } catch let error as OutboxError {
            throw SendCLI.reportOutboxFailure(error)
        }
    }

    /// Builds this command's `OutboxMessage` from its already-parsed flags
    /// plus the sending account's own address. Pure and `Runtime`-free
    /// (needs no Keychain/network), so it's the seam the "dry-run enqueue
    /// against a temp DB" tests exercise directly instead of going through
    /// `run()`.
    func buildMessage(from address: String, bodyText: String, attachments: [Attachment]) -> OutboxMessage {
        OutboxMessage(
            from: address, to: to, subject: subject, bodyText: bodyText, attachments: attachments)
    }
}

/// Replies to an existing thread, threading correctly off the thread's own
/// newest message (spec §7.1's full triple — see `Outbox.replyMessage`).
///
/// `threadID` is a Gmail thread id (`MessageRow.threadID`), not a message
/// id — the CLI has no surface exposing it yet (a follow-up carry-forward;
/// `hudson list`/`hudson show` currently print only message ids), so for
/// now a caller derives it from a synced account's own Gmail UI or a
/// future `hudson show --thread` addition.
struct ReplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Reply to an existing thread."
    )

    @Argument(help: "The Gmail thread id to reply to.")
    var threadID: String

    @Flag(name: .customLong("all"), help: "Reply to all recipients on the original message.")
    var replyAll = false

    @Option(help: "Message body (plain text). Omit to read from stdin.")
    var body: String?

    func run() async throws {
        do {
            let runtime = try await Runtime.bootstrap()
            let bodyText = try SendCLI.resolveBody(body)
            let message = try await replyMessage(
                to: threadID, account: runtime.account.email, database: runtime.database,
                from: runtime.account.email, bodyText: bodyText, replyAll: replyAll)
            try await SendCLI.enqueueFlushAndReport(message, runtime: runtime)
        } catch let error as GmailError {
            throw reportAndFail(error)
        } catch let error as ReplyBuilderError {
            throw SendCLI.reportReplyFailure(error)
        } catch let error as OutboxError {
            throw SendCLI.reportOutboxFailure(error)
        }
    }
}

/// Shared execution path for `hudson send`/`hudson reply` — the Outbox
/// twin of `TriageRunner` (`TriageCommands.swift`): a pure/testable local
/// step (here, `SendService.enqueue`, a durable SQLite write with no
/// network involved) followed by a best-effort network flush whose failure
/// is reported, never a hard command failure, because the local durable
/// enqueue already succeeded and will retry on the next flush.
enum SendCLI {
    /// `--body`, or the entirety of stdin if omitted — the
    /// `[--body <text> | stdin]` half of both commands' interface. A send
    /// always needs SOME body text, so an empty result (flag omitted AND
    /// stdin empty/closed) is a user error, not a valid blank email.
    static func resolveBody(_ explicit: String?) throws -> String {
        if let explicit { return explicit }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            throw ValidationError("Provide --body <text> or pipe the message body via stdin.")
        }
        return text
    }

    /// Reads each `--attach` path off disk into an `Attachment`, inferring
    /// its MIME type from the file extension via `UniformTypeIdentifiers`
    /// (a system framework, not a new external dependency) rather than a
    /// hand-rolled extension table. Falls back to the generic binary type
    /// for an extension `UTType` doesn't recognize.
    static func loadAttachments(_ paths: [String]) throws -> [Attachment] {
        try paths.map { path in
            guard let data = FileManager.default.contents(atPath: path) else {
                throw ValidationError("Could not read attachment: \(path)")
            }
            let url = URL(fileURLWithPath: path)
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            return Attachment(filename: url.lastPathComponent, mimeType: mimeType, data: data)
        }
    }

    /// Enqueues `message` (mints the Message-ID, MIME-builds + size
    /// validates, persists `pending`/`held` — `SendService.enqueue`),
    /// prints the queued confirmation, then attempts one `flushOnce` pass
    /// exactly like `SyncCommand` flushes the mutation queue. Reports the
    /// job's resulting state afterward: the sent Gmail id, or — since the
    /// undo-send hold usually still has the whole job on hold at this
    /// point — the still-open undo window.
    ///
    /// `flushOnce` drains EVERY claimable job on the account, not just the
    /// one just enqueued here — so on M5 (no daemon/scheduler) this
    /// piggybacked flush is the ONLY thing that can ever drain a job an
    /// EARLIER `hudson send`/`hudson reply` left `held`, once its own undo
    /// window has since elapsed. Its return value (`confirmedThisPass`) is
    /// threaded into `report` so that silent side-effect send is surfaced
    /// rather than buried behind this call's own job id — see `reportLine`.
    static func enqueueFlushAndReport(_ message: OutboxMessage, runtime: Runtime) async throws {
        let service = SendService(api: runtime.client, database: runtime.database, account: runtime.account.email)
        let jobID = try await service.enqueue(message, now: Self.nowMilliseconds())

        let safeSubject = Sanitizer.terminalSafe(message.subject, singleLine: true)
        let safeTo = message.to.map { Sanitizer.terminalSafe($0, singleLine: true) }.joined(separator: ", ")
        print("queued \"\(safeSubject)\" to \(safeTo)")

        let confirmedThisPass: Int
        do {
            confirmedThisPass = try await service.flushOnce(now: Self.nowMilliseconds())
        } catch let error as GmailError {
            // Mirrors `TriageRunner.flush`'s swallow-and-report contract:
            // the local durable enqueue above already succeeded, so a
            // delivery hiccup (offline, rate-limited, …) is reported, not a
            // command failure — the job stays queued for the next flush.
            print("held locally, will retry (\(error.cliMessage))")
            return
        } catch {
            // Non-GmailError failures here are almost always a
            // DatabaseError, whose description embeds raw SQL — never
            // print it directly (Sanitizer discipline, spec §9.1).
            print("held locally, will retry (\(type(of: error)))")
            return
        }
        await report(
            jobID: jobID, database: runtime.database, account: runtime.account.email,
            confirmedThisPass: confirmedThisPass)
    }

    /// Prints this specific job's post-flush state. `flushOnce`'s return
    /// value is an aggregate count across every job it touched this pass
    /// (including unrelated stranded jobs from a prior run), so it can't by
    /// itself answer "did THIS job send" — this reads the row back by id
    /// instead (`HudsonDatabase.sendJob`) and hands both to `reportLine`.
    private static func report(
        jobID: Int64, database: HudsonDatabase, account: String, confirmedThisPass: Int
    ) async {
        guard let job = try? await database.sendJob(id: jobID, account: account) else {
            // Shouldn't happen (we just inserted it) — fail soft rather
            // than crash the whole command over a report-only read.
            print("(job \(jobID) — unable to read back its status)")
            return
        }
        print(reportLine(job: job, jobID: jobID, confirmedThisPass: confirmedThisPass, now: Self.nowMilliseconds()))
    }

    /// Pure formatting for `report`'s output — no `Runtime`/database
    /// involved, so it's directly unit-testable against a `SendJob` read
    /// back from a temp DB.
    ///
    /// `confirmedThisPass` is `flushOnce`'s aggregate count for the WHOLE
    /// pass it just ran, across every job it touched — not just `job`. The
    /// row passed in as `job` is the one just enqueued by THIS command
    /// invocation, so it could only have become `.sent` via THIS pass;
    /// subtracting one for that case isolates how many OTHER,
    /// previously-queued jobs this same flush ALSO delivered as a side
    /// effect. M5 has no daemon/scheduler — this piggybacked flush is the
    /// only thing that can ever drain a job an earlier invocation left
    /// `held` — so that count must be surfaced, never silently dropped:
    /// otherwise a user re-running `hudson send` sees only their new job's
    /// state while an earlier one silently went out underneath them, and
    /// may resend identical content believing the first attempt never left.
    static func reportLine(job: SendJob, jobID: Int64, confirmedThisPass: Int, now: Int64) -> String {
        let otherConfirmed = max(0, confirmedThisPass - (job.state == .sent ? 1 : 0))
        let sideNote = otherConfirmed > 0
            ? " (also delivered \(otherConfirmed) other previously-queued message(s) this pass)"
            : ""
        switch job.state {
        case .sent:
            return "sent — Gmail id \(job.sentMessageID ?? "unknown")\(sideNote)"
        case .pending, .held:
            // No daemon/scheduler exists in M5 to drain this in the
            // background — waiting alone will never deliver it. Only a
            // LATER `hudson send`/`hudson reply` invocation's own
            // piggybacked flush can, once this job's hold has elapsed.
            let secondsLeft = max(0, (job.holdUntil - now) / 1_000)
            return "queued — undo window open for ~\(secondsLeft)s (job \(jobID)); "
                + "it is delivered only by a LATER `hudson send`/`hudson reply` call — "
                + "nothing sends it in the background, so waiting alone will not.\(sideNote)"
        case .inFlight:
            // Reached the wire but the outcome isn't confirmed yet (spec
            // §7.3's ambiguous-probe-miss case) — never resent automatically.
            return "sending — delivery not yet confirmed; run again to resolve (job \(jobID)).\(sideNote)"
        case .failed:
            return "send failed (job \(jobID)).\(sideNote)"
        }
    }

    /// `OutboxError` → a plain stderr message + failure exit code, mirroring
    /// `reportAndFail(_: GmailError)`'s posture for the Outbox's own error type.
    static func reportOutboxFailure(_ error: OutboxError) -> Error {
        let message: String
        switch error {
        case .tooLarge(let encodedBytes):
            message = "Message too large: \(encodedBytes) bytes exceeds the "
                + "\(MimeBuilder.maxEncodedBytes)-byte cap."
        case .invalidHeaderValue(let field):
            message = "Invalid value for \(field): header fields can't contain a raw newline."
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return ExitCode.failure
    }

    /// `ReplyBuilderError` → a plain stderr message + failure exit code.
    static func reportReplyFailure(_ error: ReplyBuilderError) -> Error {
        switch error {
        case .emptyThread(let threadID):
            let safeThreadID = Sanitizer.terminalSafe(threadID, singleLine: true)
            FileHandle.standardError.write(Data(
                ("No local messages found for thread \(safeThreadID) — run `hudson sync` first.\n")
                    .utf8))
            return ExitCode.failure
        }
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
