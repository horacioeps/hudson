import Foundation

/// Request body for messages.modify.
private struct ModifyBody: Encodable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

/// Request body for messages.batchModify.
private struct BatchModifyBody: Encodable {
    let ids: [String]
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

extension GmailClient {
    /// Applies label changes to one message and returns the updated Message —
    /// its `historyId` is the retirement gate for the optimistic overlay.
    /// Foreground triage (a person waiting on archive/star/read) — sent on
    /// the `.interactive` quota lane so a saturated backfill never queues it.
    public func modify(
        id: String, addLabelIDs: [String], removeLabelIDs: [String]
    ) async throws -> GmailMessage {
        try await post(
            template: "users/me/messages/{id}/modify",
            path: "users/me/messages/\(id)/modify",
            body: ModifyBody(addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs),
            cost: GmailQuotaCost.messagesModify, class: .interactive)
    }

    /// Applies the SAME label change to up to 1000 messages (204, no body).
    /// Cheaper per-message than N modifies; used to coalesce rapid triage.
    /// Also `.interactive` — see `modify` above.
    public func batchModify(
        ids: [String], addLabelIDs: [String], removeLabelIDs: [String]
    ) async throws {
        try await postVoid(
            template: "users/me/messages/batchModify",
            path: "users/me/messages/batchModify",
            body: BatchModifyBody(ids: ids, addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs),
            cost: GmailQuotaCost.messagesBatchModify, class: .interactive)
    }
}
