/// `users.getProfile` response. `historyId` is the sync cursor M2's backfill
/// records before it starts (spec §4.1).
public struct Profile: Decodable, Equatable, Sendable {
    public let emailAddress: String
    public let messagesTotal: Int
    public let threadsTotal: Int
    public let historyId: String

    /// Initializes a profile from a `users.getProfile` response.
    public init(emailAddress: String, messagesTotal: Int, threadsTotal: Int, historyId: String) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }
}
