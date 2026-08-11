/// One message's server-state snapshot, as SyncEngine hands it to the Store.
/// `historyID` is Gmail's per-message version — the §4.2 anti-clobber guard.
public struct MessageSnapshot: Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let historyID: Int64
    public let internalDate: Int64
    public let fromLine: String
    public let toLine: String
    public let subject: String
    public let snippet: String
    public let labelIDs: [String]
    /// This message's own RFC 5322 `Message-ID` header, straight off the
    /// wire (e.g. `"<abc@mail.gmail.com>"`) — persisted (M5 Task 5) so a
    /// LATER reply to this message can build the threading triple's
    /// `In-Reply-To` leg (spec §7.1) without a live network round-trip.
    /// `nil` only when the source fetch didn't carry headers (a
    /// `format: "minimal"` labels-only patch never reaches `applySnapshot`
    /// at all — see `MutationFlusher.reconvergeMessage`) or, rarely, the
    /// message genuinely lacks the header; every `format: "metadata"`/
    /// `"full"` hydration populates it via `GmailMessage.header(...)`.
    public let rfc822MessageID: String?
    /// This message's own `References` header, stored EXACTLY as Gmail
    /// sent it — a single whitespace-separated string of `<id>` tokens per
    /// RFC 5322 §3.6.4 — not parsed into an array at write time. The only
    /// consumer (`Outbox.replyMessage`) needs it turned back into a raw,
    /// whitespace-joined string anyway (that's what the OUTGOING
    /// `References:` header looks like too), so parsing here would be
    /// wasted work later undone.
    public let referencesHeader: String?

    /// Memberwise — SyncEngine maps Gmail DTOs into this. The two
    /// threading fields default to `nil` so every pre-Task-5 call site
    /// (existing test seeds, `DemoData`) keeps compiling unchanged; only
    /// `SnapshotMapping` needs to actually pass them going forward.
    public init(
        id: String, threadID: String, historyID: Int64, internalDate: Int64,
        fromLine: String, toLine: String, subject: String, snippet: String,
        labelIDs: [String], rfc822MessageID: String? = nil, referencesHeader: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.internalDate = internalDate
        self.fromLine = fromLine
        self.toLine = toLine
        self.subject = subject
        self.snippet = snippet
        self.labelIDs = labelIDs
        self.rfc822MessageID = rfc822MessageID
        self.referencesHeader = referencesHeader
    }
}

/// What happened to a snapshot write (spec §4.2).
public enum SnapshotOutcome: Sendable, Equatable {
    case applied
    /// Discarded: the store already holds a newer version of this message.
    case stale
    /// Discarded: the message was deleted; late snapshots must not resurrect it.
    case tombstoned
}

/// One ordered change from Gmail's history feed.
public struct HistoryChange: Sendable {
    public enum Kind: Sendable {
        case added(MessageSnapshot)
        case deleted(id: String)
        /// Label state after the event, with the history record's id as version.
        case labels(id: String, historyID: Int64, labelIDs: [String])
    }
    public let kind: Kind

    /// Wraps one change; order within the array passed to `applyHistory` matters.
    public init(kind: Kind) { self.kind = kind }
}
