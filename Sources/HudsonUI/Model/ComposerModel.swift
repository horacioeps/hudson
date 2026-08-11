import Foundation
import Outbox
import Store

/// The compose sheet's view model: drives new compose, reply-with-threading,
/// the durable send, and the undo-send window. `@MainActor @Observable` for
/// the same reason as every other Hudson view model (`SearchModel`,
/// `ThreadModel`) — SwiftUI reads `to`/`subject`/`bodyText`/`banner` on the
/// main thread and every Store/Send call here is `async`, so nothing on this
/// class blocks a cooperative-pool thread.
///
/// **Privacy #1 — send is user-initiated only.** Nothing here sends on its
/// own: a job only ever reaches the wire because the user tapped Send, which
/// enqueues it through `SendService`'s dedup state machine (never a direct
/// transport call). The undo-send window is real — `send()` enqueues with the
/// default 15s hold, and `undo()` calls `SendService.cancel` while that hold
/// is still open, so a mistaken send is genuinely recoverable.
///
/// **The `makeService` seam.** The service is built lazily, per send, from a
/// factory injected at init. Production defaults it to `SendBootstrap`
/// (Keychain → `GmailClient` → `SendService`); tests pass a factory returning
/// a `SendService` layered over a fake `SendTransport`, so the whole send/undo
/// path is exercised against real `send_jobs` rows without a network or a
/// Keychain.
@MainActor
@Observable
public final class ComposerModel {
    /// What the current draft is: a fresh message, or a reply that must
    /// thread back to `threadID` (Gmail keeps it in the same conversation).
    public enum Mode: Equatable {
        case new
        case reply(threadID: String)
    }

    private let database: HudsonDatabase
    private let account: AccountRecord?

    /// Builds the `SendService` for a send. A closure (not a stored service)
    /// so credentials are read fresh each time and so tests can inject a
    /// fake-transport-backed service — see the type's doc comment.
    private let makeService: () -> SendService?

    // MARK: - Editable draft fields (bound to the compose sheet)

    /// Comma-separated recipient lists as the user typed/edited them; split
    /// into individual addresses only at send time (`splitAddressList`).
    public var to: String = ""
    public var cc: String = ""
    public var subject: String = ""
    public var bodyText: String = ""

    public private(set) var mode: Mode = .new

    /// The reply's threading scaffold, built once by `startReply` from the
    /// thread's newest message (recipients + `In-Reply-To`/`References` +
    /// Gmail `threadID` + normalized subject). The user edits `bodyText`
    /// freely; `send()` recombines this scaffold's threading legs with that
    /// edited body. `nil` in `.new` mode.
    private var replyScaffold: OutboxMessage?

    /// The id of the job the last successful `send()` enqueued, exposed for
    /// the undo affordance for as long as its hold is open. `nil` before any
    /// send, after a successful `undo()`, AND once `undoHoldWindow` elapses
    /// on its own (via `scheduleUndoExpiry`) — so `justSentUndoJobID != nil`
    /// is always an accurate "undo is still possible" signal, never a stale
    /// one a caller has to separately time out. The undo toast (Task 3) is a
    /// PURE function of this property (`ComposerView.bottomToast`) — it
    /// carries no view-local visibility state of its own, precisely so the
    /// toast reads correctly regardless of when/whether the view showing it
    /// was mounted relative to the send.
    public private(set) var justSentUndoJobID: Int64?

    /// The `SendService` the last `send()` used, retained so `undo()` cancels
    /// through the SAME service instance that enqueued the job.
    private var lastSendService: SendService?

    /// Auto-clears `justSentUndoJobID` once `undoHoldWindow` elapses —
    /// see `scheduleUndoExpiry`. Stored (not fire-and-forget) so a NEWER
    /// send/undo/reset can cancel an EARLIER job's still-pending timer:
    /// without this, two sends in quick succession from the same reused
    /// `ComposerModel` would let the first job's timer fire at the first
    /// job's deadline and blindly clear whatever `justSentUndoJobID` holds
    /// at that moment — including a second, still-valid job's handle.
    private var undoExpiryTask: Task<Void, Never>?

    /// True from tapping Send until the enqueue resolves — guards against a
    /// double-tap enqueuing the same draft twice.
    public private(set) var isSending = false

    /// A user-visible strip for compose-level state (no account connected, a
    /// send/undo failure, an undo outcome). `nil` when there's nothing to say.
    public private(set) var banner: String?

    /// Called after a successful `send()` so the presenter (Task 4's
    /// `AppModel`) can dismiss the sheet. The draft's undo handle
    /// (`justSentUndoJobID`) deliberately OUTLIVES the close, so the undo
    /// toast can still act while the sheet is gone.
    public var onClose: (() -> Void)?

    /// Mirrors `AppModel`'s own text so the "no account" story reads
    /// identically wherever the user hits it.
    private static let connectAccountBannerText = "Connect an account in Terminal: `hudson auth`"

    /// How long a just-sent job's undo handle stays valid before this model
    /// auto-clears it (`scheduleUndoExpiry`) — the SAME duration `send()`
    /// passes to `SendService.enqueue`'s own `undoHold` parameter, so the
    /// model's local auto-clear and the real, durable hold it mirrors can
    /// never drift apart (a single value, injected once here, rather than
    /// two independently-maintained constants). Defaults to `enqueue`'s own
    /// default (`.seconds(15)`, `Sources/Outbox/SendService.swift`);
    /// production callers omit it, tests inject a short duration so the
    /// auto-expiry/keyed-timer behavior is checkable without a real 15s
    /// sleep (see `ComposerModelTests`' undo-window tests).
    private let undoHoldWindow: Duration

    /// Only `pendingCountTask`-style stored `Task`s need cancelling here —
    /// matches `AppModel`/`InboxModel`'s own `isolated deinit` convention
    /// (SE-0371): `undoExpiryTask` is `@MainActor`-isolated storage, so a
    /// plain `nonisolated deinit` couldn't touch it.
    isolated deinit {
        undoExpiryTask?.cancel()
    }

    /// `makeService` is optional-with-nil rather than a defaulted closure
    /// because a default argument expression can't capture the sibling
    /// `database`/`account` parameters — so the real `SendBootstrap` default
    /// is assembled here in the body instead. Production callers omit it;
    /// tests pass their fake-backed factory.
    public init(
        database: HudsonDatabase,
        account: AccountRecord?,
        makeService: (() -> SendService?)? = nil,
        undoHoldWindow: Duration = .seconds(15)
    ) {
        self.database = database
        self.account = account
        self.makeService = makeService ?? {
            guard let account else { return nil }
            return SendBootstrap.makeService(database: database, account: account)
        }
        self.undoHoldWindow = undoHoldWindow
    }

    // MARK: - Draft lifecycle

    /// Resets to a blank new-compose draft. The presenter shows the sheet
    /// after calling this.
    public func startNew() {
        mode = .new
        replyScaffold = nil
        to = ""
        cc = ""
        subject = ""
        bodyText = ""
        banner = nil
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        justSentUndoJobID = nil
    }

    /// Prepares a reply to `threadID`: builds the full threading triple from
    /// the thread's newest message via `Outbox.replyMessage` (the same path
    /// `hudson reply` uses), then prefills the user-visible `to`/`subject`
    /// and seeds `bodyText` with a quoted copy of the original for the user
    /// to type above. An empty/unknown thread leaves a banner and stays in
    /// whatever mode it was — never crashes.
    public func startReply(threadID: String) async {
        let fromAddress = account?.email ?? ""
        do {
            // Build the scaffold with an EMPTY body — the threading legs and
            // recipients are all we take from it here; the visible `bodyText`
            // (quoted below) is what the user edits, and `send()` recombines
            // the two.
            let scaffold = try await replyMessage(
                to: threadID, account: fromAddress, database: database,
                from: fromAddress, bodyText: "", replyAll: false)
            replyScaffold = scaffold
            mode = .reply(threadID: threadID)
            to = scaffold.to.joined(separator: ", ")
            cc = scaffold.cc.joined(separator: ", ")
            subject = scaffold.subject
            bodyText = await quotedReplyPrefill(threadID: threadID)
            banner = nil
            undoExpiryTask?.cancel()
            undoExpiryTask = nil
            justSentUndoJobID = nil
        } catch {
            // The only failure `replyMessage` throws is `emptyThread` (a
            // thread this account never synced) — surface it, don't crash.
            banner = "Couldn't open a reply for this thread."
        }
    }

    // MARK: - Send / undo

    /// Enqueues the current draft as a durable send job and reports its undo
    /// handle. New mode builds the message from the fields; reply mode
    /// recombines the stored threading scaffold with the edited `bodyText`.
    /// With no connected account the factory returns `nil` and this only sets
    /// the connect banner — it never sends or crashes. On success the fields
    /// clear, `justSentUndoJobID` opens the undo window, and `onClose` fires;
    /// `flushOnce` is kicked off but, by design, won't touch the wire until
    /// the undo hold elapses.
    public func send() async {
        guard !isSending else { return }
        guard let message = buildOutgoingMessage() else { return }
        guard let service = makeService() else {
            banner = Self.connectAccountBannerText
            return
        }

        isSending = true
        banner = nil
        defer { isSending = false }

        let now = Self.nowMilliseconds()
        do {
            let jobID = try await service.enqueue(message, undoHold: undoHoldWindow, now: now)
            lastSendService = service
            justSentUndoJobID = jobID
            scheduleUndoExpiry(forJobID: jobID)
            // Kick a flush pass, but it deliberately delivers nothing yet: the
            // job is still inside its undo hold, so `claimSendable` skips it.
            // The pass exists to resolve any crash-stranded jobs; the actual
            // post-hold delivery is a later-wired concern (a periodic flush).
            Task { _ = try? await service.flushOnce(now: Self.nowMilliseconds()) }
            clearDraftFields()
            onClose?()
        } catch {
            // A build/size or Store failure — keep the draft intact so the
            // user doesn't lose what they wrote.
            banner = "Couldn't send — check the message and try again."
        }
    }

    /// Undo-send: cancels the just-enqueued job while its hold is still open.
    /// Reports whether it actually cancelled (`false` means the hold already
    /// elapsed and the send is in motion). Clears the undo handle on a
    /// successful cancel so the toast dismisses.
    public func undo() async {
        guard let jobID = justSentUndoJobID, let service = lastSendService else { return }
        let now = Self.nowMilliseconds()
        do {
            let cancelled = try await service.cancel(jobID: jobID, now: now)
            if cancelled {
                undoExpiryTask?.cancel()
                undoExpiryTask = nil
                justSentUndoJobID = nil
                banner = "Send cancelled."
            } else {
                banner = "Too late to undo — already sent."
            }
        } catch {
            banner = "Couldn't undo the send."
        }
    }

    // MARK: - Message assembly

    /// Assembles the `OutboxMessage` to enqueue. New mode reads the current
    /// fields; reply mode takes the stored scaffold's threading legs and
    /// swaps in the edited body — so a reply keeps `threadID`/`In-Reply-To`/
    /// `References` even though the user rewrote the text. Returns `nil` only
    /// in the impossible "reply mode with no scaffold" case (guarded so it
    /// can't send an untethered message).
    private func buildOutgoingMessage() -> OutboxMessage? {
        switch mode {
        case .new:
            return OutboxMessage(
                from: account?.email ?? "",
                to: Self.splitAddressList(to),
                cc: Self.splitAddressList(cc),
                subject: subject,
                bodyText: bodyText)
        case .reply:
            guard let scaffold = replyScaffold else { return nil }
            return OutboxMessage(
                from: scaffold.from,
                to: scaffold.to,
                cc: scaffold.cc,
                bcc: scaffold.bcc,
                subject: scaffold.subject,
                bodyText: bodyText,
                bodyHTML: nil,
                attachments: scaffold.attachments,
                inReplyTo: scaffold.inReplyTo,
                references: scaffold.references,
                threadID: scaffold.threadID)
        }
    }

    /// Seeds a reply's `bodyText` with a quoted copy of the thread's newest
    /// message — the familiar "type above the quote" layout. Falls back to the
    /// message's snippet when its full body isn't hydrated yet, and to an
    /// empty draft if the thread can't be read (the scaffold, built from the
    /// same read moments earlier, is what actually threads the reply — the
    /// quote is a convenience).
    private func quotedReplyPrefill(threadID: String) async -> String {
        let email = account?.email ?? ""
        guard let messages = try? await database.threadMessages(threadID: threadID, account: email),
            let newest = messages.last
        else { return "" }

        // `try?` flattens to `MessageBody?`; `plainText` is itself optional
        // (nil until sync hydrates the body), so fall back to the snippet.
        let fetchedBody = try? await database.messageBody(id: newest.id, account: email)
        let original = fetchedBody?.plainText ?? newest.snippet
        let quoted = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        // Two blank lines above the attribution give the user room to type
        // their reply before the quoted original.
        return "\n\nOn \(newest.fromLine) wrote:\n\(quoted)"
    }

    private func clearDraftFields() {
        to = ""
        cc = ""
        subject = ""
        bodyText = ""
        replyScaffold = nil
        mode = .new
    }

    // MARK: - Undo-hold timing

    /// Schedules `justSentUndoJobID` to self-clear after `undoHoldWindow`,
    /// so a view rendering the undo toast as a pure function of that
    /// property (`ComposerView.bottomToast`) needs no timer of its own.
    /// Cancels any still-pending timer from an earlier job first — see
    /// `undoExpiryTask`'s doc comment — and the scheduled closure itself
    /// re-checks `justSentUndoJobID == jobID` right before clearing, so
    /// even a task that already slipped past cancellation (a race between
    /// `Task.cancel()` and the sleep resolving) can't stomp a newer job's
    /// still-valid handle, nor fire after `undo()` already cleared this
    /// one.
    private func scheduleUndoExpiry(forJobID jobID: Int64) {
        undoExpiryTask?.cancel()
        // Captured by value (it's a `let`) rather than read off `self`
        // inside the `Task` — `self` is only weakly captured below, so
        // reading an instance property off it would need an extra
        // `self?.` hop that's pointless for an immutable value already
        // known here.
        let holdWindow = undoHoldWindow
        undoExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: holdWindow)
            guard let self, !Task.isCancelled else { return }
            if self.justSentUndoJobID == jobID {
                self.justSentUndoJobID = nil
            }
        }
    }

    // MARK: - Helpers

    /// Splits a comma-separated recipient field into trimmed, non-empty
    /// addresses. Kept intentionally simple (comma-only) to match the plain
    /// compose fields — the reply path never routes through here (it carries
    /// the scaffold's already-parsed address arrays).
    private static func splitAddressList(_ field: String) -> [String] {
        field
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Wall-clock milliseconds since the epoch — the unit `SendService`'s hold
    /// window and cancel check are expressed in (spec §7.3). Real time is
    /// correct here: an undo window is a genuine human-time affordance, not a
    /// golden-file value to pin.
    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
