/// A message referenced by a history record (post-change state nested inside).
public struct ChangedMessage: Decodable, Sendable {
    public let message: GmailMessage
}

/// One history record; each array holds the changes of that kind.
public struct HistoryRecord: Decodable, Sendable {
    public let id: String
    public let messagesAdded: [ChangedMessage]?
    public let messagesDeleted: [ChangedMessage]?
    public let labelsAdded: [ChangedMessage]?
    public let labelsRemoved: [ChangedMessage]?
}

/// One page of `history.list`. `historyId` is the new cursor after this page.
public struct HistoryPage: Decodable, Sendable {
    public let history: [HistoryRecord]?
    public let nextPageToken: String?
    public let historyId: String?

    /// Initializes a history page.
    public init(history: [HistoryRecord]?, nextPageToken: String?, historyId: String?) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
}
