import ArgumentParser
import Foundation
import GmailKit
import Store
import SyncEngine

/// One label delta a triage command wants applied — the vocabulary every
/// triage command (`archive`, `star`, `label`, `undo`, …) speaks in.
struct LabelDelta: Equatable {
    let labelID: String
    let op: LabelOp
}

/// Arguments shared by every optimistic triage command: the message id and
/// the opt-out from the post-enqueue network flush.
struct TriageArguments: ParsableArguments {
    /// The message id (first column of `hudson list`).
    @Argument(help: "The message id (first column of `hudson list`).")
    var id: String

    /// Leaves the change queued locally instead of attempting a network
    /// flush — useful offline, or when batching several triage actions
    /// before a single `hudson sync` drains them all.
    @Flag(name: .customLong("no-flush"), help: "Enqueue locally only; skip the network flush.")
    var noFlush = false

    init() {}
}

/// Shared execution path for every optimistic triage command (spec M3):
/// enqueue locally via `LocalRuntime` (instant, no Keychain, so it works
/// offline), print the resulting effective state, then best-effort flush via
/// `Runtime.bootstrap()` unless suppressed. A flush failure is reported but
/// never fails the command — the local, already-durable enqueue is the
/// effect the command promises; the network send is just delivery.
enum TriageRunner {
    /// Opens a fresh `LocalRuntime`, enqueues `deltas`, prints the result,
    /// and (unless `noFlush`) attempts the flush. Used directly by the
    /// simple triage commands; `undo` calls `enqueueAndReport`/`flush`
    /// individually since it needs the runtime to read `pendingMutations` first.
    static func apply(id: String, deltas: [LabelDelta], action: String, noFlush: Bool) async throws {
        do {
            let runtime = try await LocalRuntime.local()
            try await enqueueAndReport(id: id, deltas: deltas, action: action, runtime: runtime)
            guard !noFlush else { return }
            await flush()
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }

    /// Writes `deltas` to the local mutation queue and prints the message's
    /// new effective label state (canonical labels overlaid with every live
    /// delta, including the ones just enqueued — see `HudsonDatabase.message`).
    static func enqueueAndReport(
        id: String, deltas: [LabelDelta], action: String, runtime: LocalRuntime
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for delta in deltas {
            try await runtime.database.enqueueMutation(
                messageID: id, labelID: delta.labelID, op: delta.op,
                account: runtime.account.email, now: now)
        }
        let safeID = Sanitizer.terminalSafe(id, singleLine: true)
        if let fetched = try await runtime.database.message(id: id, account: runtime.account.email) {
            // Label ids are Gmail's own vocabulary, but user-created labels
            // are user-named (e.g. a custom "Label_16" display name is
            // arbitrary text one level up) — sanitize every one printed here,
            // matching the message-id treatment above.
            let labels = fetched.row.labelIDs
                .map { Sanitizer.terminalSafe($0, singleLine: true) }
                .joined(separator: ", ")
            print("\(action) \(safeID)  labels: \(labels)")
        } else {
            // No FK from mutation_queue to messages (Task 2) — the enqueue
            // above still succeeded and will flush normally; there's just
            // nothing local yet to show as the "effective state".
            print("\(action) \(safeID)  (queued — no local copy of this message yet)")
        }
    }

    /// Attempts one network flush pass. The local effect already committed
    /// by the time this runs, so any failure here — offline, Keychain gate,
    /// Gmail rejecting the request — is reported and swallowed rather than
    /// failing the command.
    static func flush() async {
        do {
            let runtime = try await Runtime.bootstrap()
            let report = try await runtime.flusher.flushOnce()
            print("flushed: \(report.flushed) sent, \(report.retired) retired, \(report.dropped) dropped")
        } catch let error as GmailError {
            print("queued, will retry (\(error.cliMessage))")
        } catch {
            // Non-GmailError failures here are almost always a DatabaseError,
            // whose description embeds raw SQL — never print it directly
            // (Sanitizer discipline, spec §9.1); the type name is enough to
            // diagnose without leaking query text.
            print("queued, will retry (\(type(of: error)))")
        }
    }
}

/// Archives a message by removing it from the inbox.
struct ArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive", abstract: "Archive a message (remove it from the inbox).")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        try await TriageRunner.apply(
            id: args.id, deltas: [LabelDelta(labelID: "INBOX", op: .remove)],
            action: "archived", noFlush: args.noFlush)
    }
}

/// Restores a message to the inbox.
struct UnarchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unarchive", abstract: "Restore a message to the inbox.")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        try await TriageRunner.apply(
            id: args.id, deltas: [LabelDelta(labelID: "INBOX", op: .add)],
            action: "unarchived", noFlush: args.noFlush)
    }
}

/// Stars a message.
struct StarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "star", abstract: "Star a message.")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        try await TriageRunner.apply(
            id: args.id, deltas: [LabelDelta(labelID: "STARRED", op: .add)],
            action: "starred", noFlush: args.noFlush)
    }
}

/// Unstars a message.
struct UnstarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unstar", abstract: "Remove the star from a message.")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        try await TriageRunner.apply(
            id: args.id, deltas: [LabelDelta(labelID: "STARRED", op: .remove)],
            action: "unstarred", noFlush: args.noFlush)
    }
}

/// Marks a message read.
struct ReadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read", abstract: "Mark a message read.")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        try await TriageRunner.apply(
            id: args.id, deltas: [LabelDelta(labelID: "UNREAD", op: .remove)],
            action: "marked read", noFlush: args.noFlush)
    }
}

/// Marks a message unread.
struct UnreadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unread", abstract: "Mark a message unread.")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        try await TriageRunner.apply(
            id: args.id, deltas: [LabelDelta(labelID: "UNREAD", op: .add)],
            action: "marked unread", noFlush: args.noFlush)
    }
}

/// Adds and/or removes arbitrary labels on a message in one enqueue.
struct LabelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label", abstract: "Add or remove labels on a message.")

    @OptionGroup var args: TriageArguments

    @Option(name: .customLong("add"), help: "Label id to add (repeat for multiple).")
    var add: [String] = []

    @Option(name: .customLong("remove"), help: "Label id to remove (repeat for multiple).")
    var remove: [String] = []

    func run() async throws {
        let deltas = add.map { LabelDelta(labelID: $0, op: .add) }
            + remove.map { LabelDelta(labelID: $0, op: .remove) }
        guard !deltas.isEmpty else {
            print("Nothing to do — pass --add and/or --remove with a label id.")
            return
        }
        try await TriageRunner.apply(
            id: args.id, deltas: deltas, action: "labeled", noFlush: args.noFlush)
    }
}

/// Undoes the most recent still-live triage action on a message.
///
/// This is deliberately an inverse-delta *enqueue*, never a direct
/// un-modify: reaching into the queue and unilaterally deleting/flipping the
/// row would race the flusher, which can claim and send that very row
/// concurrently (TOCTOU — the row could go from `pending` to sent between
/// the read here and a direct mutation). Enqueuing the inverse through the
/// exact same `enqueueMutation` path every other triage command uses is
/// race-free by construction: it's one atomic write that either cancels a
/// still-pending row (net no-op, nothing was ever sent) or lays down a new
/// delta that the flusher will send and converge normally.
///
/// Every other triage command auto-flushes inline, so by the time a user
/// separately runs `hudson undo <id>` the delta has usually already been
/// sent AND retired — `pendingMutations` then has nothing for this message.
/// That is NOT "nothing to undo": the action genuinely happened and is
/// still reversible, just no longer via a queued-delta cancel. Treating it
/// as a hard failure would be misleading (post-review fix), so this case
/// exits 0 with an honest "already synced" message plus the specific
/// command that reverses it, inferred from the message's current labels.
/// A true one-keystroke undo-after-sync (an actual action log + reverse) is
/// a UI-phase undo-toast feature, out of scope for the M3 CLI.
struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo", abstract: "Undo the most recent triage action on a message.")

    @OptionGroup var args: TriageArguments

    func run() async throws {
        do {
            let runtime = try await LocalRuntime.local()
            let pending = try await runtime.database.pendingMutations(account: runtime.account.email)
            // `pendingMutations` is oldest-first (id ascending) — the newest
            // live delta for this message is the last match.
            if let newest = pending.last(where: { $0.messageID == args.id }) {
                let inverse = Self.inverseDelta(labelID: newest.labelID, op: newest.op)
                try await TriageRunner.enqueueAndReport(
                    id: args.id, deltas: [inverse], action: "undone", runtime: runtime)
                guard !args.noFlush else { return }
                await TriageRunner.flush()
                return
            }
            try await Self.reportAlreadySynced(id: args.id, runtime: runtime)
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }

    /// No live queued delta for this message. Distinguishes "never heard of
    /// this id" (a genuine error — exit 1) from "already synced" (exit 0,
    /// with an honest, actionable message: never a hard failure that
    /// implies the earlier triage action didn't happen). `static` (no `self`
    /// dependency) so it's directly testable against an isolated `LocalRuntime`.
    static func reportAlreadySynced(id: String, runtime: LocalRuntime) async throws {
        let safeID = Sanitizer.terminalSafe(id, singleLine: true)
        guard let fetched = try await runtime.database.message(id: id, account: runtime.account.email) else {
            print("No message \(safeID) in the local store.")
            throw ExitCode.failure
        }
        print("\(safeID) has no pending triage action — it's already synced to Gmail.")
        let reversals = Self.suggestedReversals(labelIDs: fetched.row.labelIDs)
        if reversals.isEmpty {
            print("Its current labels don't suggest an obvious reverse — use `hudson label \(safeID)` to change it directly.")
        } else {
            print("To reverse it: " + reversals.map { "hudson \($0) \(safeID)" }.joined(separator: " or "))
        }
    }

    /// The delta that cancels a delta of `op` on `labelID` — same label,
    /// opposite direction. Pure and free of any store/network dependency so
    /// it's directly testable: the one piece of the in-window undo path
    /// with actual logic.
    static func inverseDelta(labelID: String, op: LabelOp) -> LabelDelta {
        LabelDelta(labelID: labelID, op: op == .add ? .remove : .add)
    }

    /// Heuristic reverse-command suggestions from a message's CURRENT
    /// effective labels — there's no action log once a delta has retired,
    /// so this doesn't reconstruct "what actually happened", only what a
    /// sensible reverse would be given where the message sits now. Pure and
    /// directly testable.
    static func suggestedReversals(labelIDs: [String]) -> [String] {
        var commands: [String] = []
        if !labelIDs.contains("INBOX") { commands.append("unarchive") }
        if labelIDs.contains("STARRED") { commands.append("unstar") }
        if labelIDs.contains("UNREAD") { commands.append("read") }
        return commands
    }
}
