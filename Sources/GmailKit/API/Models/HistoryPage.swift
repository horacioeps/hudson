/// The MINIMAL message shape Gmail nests in EVERY `history.list` change record
/// (`messagesAdded` / `labelsAdded` / `labelsRemoved` / `messagesDeleted`):
/// `id` (+ the message's current `labelIds`) only. Gmail does NOT include
/// `historyId`, `internalDate`, headers, or a payload here — so decoding these
/// as a full `GmailMessage` (which requires `historyId`) crashes the whole
/// `history.list` decode, which broke ALL sync the moment anything changed
/// (sending adds `SENT`; every new mail is a `messagesAdded`). A new message id
/// is reconciled by the engine fetching it in full (`SyncEngine.pollHistory`'s
/// unknown-id path), never from this stub, so `id`/`labelIds` are all we need.
public struct HistoryMessageStub: Decodable, Sendable {
    public let message: MessageStub

    public struct MessageStub: Decodable, Sendable {
        public let id: String
        public let labelIds: [String]?
    }

    public var id: String { message.id }
    public var labelIds: [String]? { message.labelIds }
}

/// One history record; each array holds the changes of that kind. ALL of them
/// carry only the minimal `HistoryMessageStub` (see above) — a new message's
/// full content is fetched separately by the engine.
public struct HistoryRecord: Decodable, Sendable {
    public let id: String
    public let messagesAdded: [HistoryMessageStub]?
    public let messagesDeleted: [HistoryMessageStub]?
    public let labelsAdded: [HistoryMessageStub]?
    public let labelsRemoved: [HistoryMessageStub]?
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
