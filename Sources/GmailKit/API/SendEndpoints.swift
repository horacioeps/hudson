import Foundation

/// Request body for `messages.send`. `raw` is the full base64url-encoded
/// RFC 5322 MIME (Outbox's `MimeBuilder` output, a later M5 task); `threadId`,
/// when present, is one leg of the threading triple (spec §7.1) — the other
/// two (References/In-Reply-To headers, matching normalized Subject) are
/// baked into `rawMIME` itself by the caller before this is ever reached.
/// `threadId` is `Optional`, and the compiler-synthesized `Encodable`
/// conformance encodes optional properties with `encodeIfPresent` — so when
/// it's `nil` the key is OMITTED from the JSON body entirely, not sent as
/// `null`. That matters: an edited-subject reply deliberately starts a new
/// Gmail thread by omitting `threadId`, and Gmail's API treats an explicit
/// `null` the same as an unset field, but omitting it is what the spec text
/// (and Task 3's `OutboxMessage`) describes, so this is written to match
/// that intent exactly rather than relying on `null` behaving the same way.
private struct SendMessageBody: Encodable {
    let raw: String
    let threadId: String?
}

/// One sent message, as returned by `messages.send`. `id` is Gmail's own
/// message id — distinct from the RFC `Message-ID` header used for dedup
/// and threading, and what `SendService` persists as `SendJob.sentMessageID`
/// once a send is confirmed.
public struct SentMessage: Decodable, Sendable, Equatable {
    public let id: String
    public let threadId: String
    public let labelIds: [String]

    /// Initializes a sent-message result.
    public init(id: String, threadId: String, labelIds: [String]) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
    }
}

extension GmailClient {
    /// Sends a fully-built RFC 5322 message (`Outbox.MimeBuilder`'s output).
    /// Uses the JSON `raw` form of `messages.send` (a plain POST through the
    /// existing `post` core), not the `/upload/gmail/v1` resumable endpoint —
    /// sufficient for anything under the 35 MB MIME cap Outbox already
    /// enforces at enqueue time (spec §7.1), since the JSON body itself
    /// carries the full base64url payload.
    /// TODO(M5-large): switch very large attachments to
    /// `/upload/gmail/v1/users/me/messages/send?uploadType=resumable` for
    /// chunked upload; deferred, per the plan, past M5.
    ///
    /// Sent on the `.interactive` quota lane, never `.background`: a send is
    /// always a foreground, user-initiated action (Privacy #1 — no
    /// background/auto-send), so it must never queue behind a saturated
    /// background lane the way polling/backfill do (mirrors `modify`'s
    /// reasoning in `ModifyEndpoints.swift`).
    public func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage {
        try await post(
            template: "users/me/messages/send",
            path: "users/me/messages/send",
            body: SendMessageBody(raw: rawMIME.base64URLEncoded(), threadId: threadID),
            cost: GmailQuotaCost.messagesSend, class: .interactive)
    }

    /// The restart dedup protocol's probe (§7.3): searches `Sent` for the
    /// UUID RFC `Message-ID` `SendService.enqueue` assigned before the
    /// original send attempt. Returns Gmail's own message id on a hit, `nil`
    /// on a miss.
    ///
    /// Deliberately reports ONLY what Gmail's search index currently says —
    /// it does NOT decide whether a miss means "not sent". Search indexing
    /// lags the actual send, so a fast miss right after a crash is never
    /// proof of non-delivery; that judgment (skip / resend / wait-and-reprobe)
    /// belongs entirely to `SendService.flushOnce`, which is the one place
    /// the ambiguous-outcome rule from the Global Constraints is enforced.
    /// Query value construction is intentionally the RAW, unescaped string —
    /// `GmailClient.perform`'s shared `encodedQuery` percent-encodes every
    /// query item's value already (see `GmailClient.swift`), so escaping it
    /// again here would double-encode.
    public func findSentMessageID(rfc822MessageID: String) async throws -> String? {
        let page: MessageListPage = try await get(
            template: "users/me/messages",
            path: "users/me/messages",
            query: [
                URLQueryItem(name: "q", value: "rfc822msgid:\(rfc822MessageID) in:sent"),
                URLQueryItem(name: "maxResults", value: "1"),
            ],
            cost: GmailQuotaCost.messagesList)
        return page.messages?.first?.id
    }
}
