import Foundation

extension GmailClient {
    /// One newest-first page of message ids (spec §4.1 backfill driver).
    public func listMessages(
        pageToken: String?, maxResults: Int = 100
    ) async throws -> MessageListPage {
        var query = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get(
            template: "users/me/messages", path: "users/me/messages",
            query: query, cost: GmailQuotaCost.messagesList)
    }

    /// One message. `format` is "metadata" (headers only), "full", or "minimal".
    public func getMessage(id: String, format: String) async throws -> GmailMessage {
        try await get(
            template: "users/me/messages/{id}", path: "users/me/messages/\(id)",
            query: [URLQueryItem(name: "format", value: format)],
            cost: GmailQuotaCost.messagesGet)
    }

    /// Changes since `startHistoryID`. A 404 means the cursor expired —
    /// callers must fall back to reconciliation (spec §4.3).
    public func listHistory(
        startHistoryID: String, pageToken: String?
    ) async throws -> HistoryPage {
        var query = [URLQueryItem(name: "startHistoryId", value: startHistoryID)]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await get(
            template: "users/me/history", path: "users/me/history",
            query: query, cost: GmailQuotaCost.historyList)
    }

    /// All labels (id → name) for display.
    public func listLabels() async throws -> [GmailLabel] {
        let response: LabelListResponse = try await get(
            template: "users/me/labels", path: "users/me/labels",
            cost: GmailQuotaCost.labelsList)
        return response.labels ?? []
    }
}
