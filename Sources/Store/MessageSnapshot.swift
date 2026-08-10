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

    /// Memberwise — SyncEngine maps Gmail DTOs into this.
    public init(
        id: String, threadID: String, historyID: Int64, internalDate: Int64,
        fromLine: String, toLine: String, subject: String, snippet: String,
        labelIDs: [String]
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
