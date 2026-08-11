import Foundation
import Store

/// One message within an open thread, paired with its reading-pane UI
/// state. `Equatable` for tests only — SwiftUI diffs `ThreadModel.messages`
/// structurally via `@Observable`, not through this conformance.
public struct ThreadMessage: Identifiable, Sendable, Equatable {
    public let row: MessageRow
    /// `nil` until `ThreadModel` has fetched it (eagerly on `open` for
    /// whichever messages are expanded, or on-demand in `toggleExpanded`).
    /// A message's body never changes once Store has hydrated it — sync
    /// writes `message_bodies` exactly once per message — so a non-nil
    /// value here is cached for good; `ThreadModel` never re-fetches an id
    /// that already has one.
    public var bodyText: String?
    public var isExpanded: Bool

    public var id: String { row.id }
}

/// The reading pane's view model: observes one thread's messages (Store
/// Task 3's `observeThread`), reconciles each emission against the current
/// `messages` so a user's expand/collapse choices and already-fetched
/// bodies survive a re-emit, and lazily hydrates bodies for whichever
/// messages are expanded. `@MainActor` for the same reason as
/// `InboxModel` — SwiftUI reads `messages`/`subject`/`participants` on the
/// main thread, and every Store call here is async, so nothing on this
/// class blocks a cooperative-pool thread.
@MainActor
@Observable
public final class ThreadModel {
    public let database: HudsonDatabase
    public let account: String

    public private(set) var messages: [ThreadMessage] = []

    /// The subscription driving `messages`, (re)started by `open` —
    /// one thread at a time. Cancelled before the next one starts, and in
    /// `deinit`, so a superseded thread's loop can never win a race and
    /// overwrite `messages` with stale data — same pattern as
    /// `InboxModel.rowsTask`.
    private var observationTask: Task<Void, Never>?

    public init(database: HudsonDatabase, account: String) {
        self.database = database
        self.account = account
    }

    /// `isolated` (SE-0371) because `observationTask` is `@MainActor`-
    /// isolated storage — a plain `nonisolated deinit` can't touch it
    /// without an unsafe escape hatch. Only cancels the loop; nothing else
    /// keeps `self` alive past this since the loop captures it weakly (see
    /// `open`).
    isolated deinit {
        observationTask?.cancel()
    }

    /// (Re)subscribes to `threadID`'s messages. Safe to call more than
    /// once — e.g. the inbox selection changing re-invokes this on the
    /// same `ThreadModel` — each call cancels whatever observation was
    /// running first. Returns immediately once the loop is launched; it
    /// does not wait for the first emission (a caller that needs the
    /// first `messages` to have landed awaits that separately, e.g. in a
    /// test) — matches `InboxModel.start()`.
    public func open(threadID: String) async {
        observationTask?.cancel()
        let database = self.database
        let account = self.account
        observationTask = Task { [weak self] in
            do {
                for try await freshMessages in database.observeThread(threadID: threadID, account: account) {
                    guard let self, !Task.isCancelled else { return }
                    self.reconcile(with: freshMessages)
                    await self.loadBodiesForExpandedMessages()
                }
            } catch {
                // `observeThread` only throws on a genuine Store/SQLite
                // failure (never "no rows") — nothing to recover into
                // here; a later task wires user-facing sync/error
                // surfacing. Matches `InboxModel`'s subscriptions.
            }
        }
    }

    /// Reconciles a fresh `observeThread` emission against the current
    /// `messages`. A message id already present KEEPS its `isExpanded`/
    /// `bodyText` — a re-emit only ever means a label or message-set
    /// change on this thread (e.g. a mark-unread), never a reason to
    /// discard the user's expand/collapse choices or an already-fetched
    /// body. A message id seen for the first time defaults to collapsed,
    /// except the newest one (max `internalDate`) among the FRESH rows,
    /// which defaults expanded — Superhuman-style "read the latest, skim
    /// the rest". Because this rule is evaluated per fresh row rather
    /// than only on the very first load, a brand-new reply landing on an
    /// already-open thread becomes the newly-expanded one while every
    /// previously-seen message (including the formerly-newest one) keeps
    /// whatever state the user left it in.
    private func reconcile(with freshMessages: [MessageRow]) {
        let existingByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let newestID = freshMessages.max(by: { $0.internalDate < $1.internalDate })?.id
        messages = freshMessages.map { row in
            if let existing = existingByID[row.id] {
                return ThreadMessage(row: row, bodyText: existing.bodyText, isExpanded: existing.isExpanded)
            }
            return ThreadMessage(row: row, bodyText: nil, isExpanded: row.id == newestID)
        }
    }

    /// Fetches and caches `bodyText` for every currently-expanded message
    /// that doesn't have one yet. Skips ids that are already cached (see
    /// `ThreadMessage.bodyText`'s doc comment) — a re-emit here is cheap
    /// even on a long thread since only the newly-expanded/newly-arrived
    /// ids ever lack a body. A read that comes back with `plainText ==
    /// nil` (body not yet hydrated by sync) is deliberately left uncached
    /// so the NEXT re-emit or expand retries it.
    private func loadBodiesForExpandedMessages() async {
        let idsNeedingBody = messages.filter { $0.isExpanded && $0.bodyText == nil }.map(\.id)
        for id in idsNeedingBody {
            guard !Task.isCancelled else { return }
            guard let fetched = try? await database.message(id: id, account: account) else { continue }
            guard !Task.isCancelled, let index = messages.firstIndex(where: { $0.id == id }) else { continue }
            messages[index].bodyText = fetched.plainText
        }
    }

    /// Flips `id`'s expand state. Expanding a message whose body isn't
    /// cached yet fetches it immediately and imperatively — independent
    /// of `observationTask`'s subscription — since a body never changes
    /// once hydrated (see `ThreadMessage.bodyText`). Collapsing never
    /// clears a cached body, so re-expanding later is instant. The fetch
    /// runs in its own `Task` (this method itself isn't `async`); it
    /// re-finds `id` in `messages` before writing rather than tracking
    /// cancellation, so a stale write naturally no-ops if `id` dropped out
    /// of the thread (or the thread was switched via `open`) before the
    /// fetch completed.
    public func toggleExpanded(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].isExpanded.toggle()
        guard messages[index].isExpanded, messages[index].bodyText == nil else { return }

        let database = self.database
        let account = self.account
        Task { [weak self] in
            guard let fetched = try? await database.message(id: id, account: account) else { return }
            guard let self, let currentIndex = self.messages.firstIndex(where: { $0.id == id }) else { return }
            self.messages[currentIndex].bodyText = fetched.plainText
        }
    }

    /// The newest message by `internalDate`, or `nil` before `open`'s
    /// first emission has landed. Backs both `subject` and `participants`
    /// below.
    private var newestMessage: ThreadMessage? {
        messages.max(by: { $0.row.internalDate < $1.row.internalDate })
    }

    /// The reading pane's header subject — the newest message's, matching
    /// Gmail's own "thread subject follows the latest reply" behavior.
    /// Empty before the first emission lands.
    public var subject: String {
        newestMessage?.row.subject ?? ""
    }

    /// A compact, comma-joined preview of the thread's distinct senders —
    /// e.g. "Priya Anand, You" — in first-seen order (oldest message
    /// first, matching `messages`' own ordering). Deliberately re-derived
    /// from `messages`' own `fromLine`s rather than reusing Store's
    /// `ThreadRollup.senderDisplayName`/`from_summary`: that helper is
    /// package-internal to `Store`, and the reading pane already has every
    /// message's `fromLine` in hand here, so a second Store round-trip
    /// just to read `thread_rollup.from_summary` would be pure overhead.
    public var participants: String {
        var seen: [String] = []
        for message in messages {
            let name = Self.senderDisplayName(fromLine: message.row.fromLine)
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.append(name)
        }
        return seen.joined(separator: ", ")
    }

    /// Extracts a compact sender label from an RFC 5322 `From` header
    /// value: the display name in a `Name <email>` header (surrounding
    /// double-quotes stripped), else the email address's local part
    /// (`ada` from `ada@example.com`), else the trimmed raw value. Pure
    /// and total — `fromLine` is untrusted (sender-controlled mail
    /// headers) — never throws or crashes on malformed input. Mirrors
    /// (without reusing — package-internal) `ThreadRollup.senderDisplayName`.
    private static func senderDisplayName(fromLine: String) -> String {
        let trimmed = fromLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close
        else {
            return localPart(of: trimmed)
        }
        let namePart = trimmed[trimmed.startIndex..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let unquotedName = unquoted(namePart)
        if !unquotedName.isEmpty { return unquotedName }
        let email = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        return localPart(of: email)
    }

    /// Strips one layer of matching double-quotes (an RFC 5322
    /// quoted-string display name, e.g. `"Ada Lovelace"`), if present.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `ada` from `ada@example.com`; the whole string unchanged if there's
    /// no `@`.
    private static func localPart(of email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[email.startIndex..<at])
    }
}
