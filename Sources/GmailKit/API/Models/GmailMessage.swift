import Foundation

/// A message id/thread id pair from `messages.list`.
public struct MessageRef: Decodable, Sendable {
    public let id: String
    public let threadId: String

    /// Initializes a message reference.
    public init(id: String, threadId: String) {
        self.id = id
        self.threadId = threadId
    }
}

/// One page of `messages.list`.
public struct MessageListPage: Decodable, Sendable {
    public let messages: [MessageRef]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?

    /// Initializes a message list page.
    public init(messages: [MessageRef]?, nextPageToken: String?, resultSizeEstimate: Int?) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
}

/// A header field inside a message payload.
public struct MessageHeaderField: Decodable, Sendable {
    public let name: String
    public let value: String
}

/// The body carried by a MIME part (base64url in `data`).
public struct MessagePartBody: Decodable, Sendable {
    public let data: String?
    public let size: Int?
}

/// One node of the MIME part tree.
public struct MessagePart: Decodable, Sendable {
    public let mimeType: String?
    public let filename: String?
    public let headers: [MessageHeaderField]?
    public let body: MessagePartBody?
    public let parts: [MessagePart]?
}

/// The Message resource. `historyId` is the §4.2 version guard's source.
public struct GmailMessage: Decodable, Sendable {
    public let id: String
    public let threadId: String
    public let historyId: String
    public let internalDate: String?
    public let labelIds: [String]?
    public let snippet: String?
    public let payload: MessagePart?

    /// Case-insensitive header lookup on the top-level payload.
    public func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The text and HTML alternatives found in a message's part tree.
public struct ExtractedContent: Sendable {
    public let htmlData: Data?
    public let plainText: String?
}

extension GmailMessage {
    /// Depth-first walk: first text/plain and first text/html leaves,
    /// base64url-decoded. Attachments are ignored in M2 (lazy download later).
    public func extractContent() -> ExtractedContent {
        var plain: Data?
        var html: Data?
        func walk(_ part: MessagePart?) {
            guard let part else { return }
            if part.mimeType == "text/plain", plain == nil {
                plain = part.body?.data.flatMap(Self.decodeBase64URL)
            }
            if part.mimeType == "text/html", html == nil {
                html = part.body?.data.flatMap(Self.decodeBase64URL)
            }
            for child in part.parts ?? [] { walk(child) }
        }
        walk(payload)
        return ExtractedContent(
            htmlData: html,
            plainText: plain.map { String(decoding: $0, as: UTF8.self) })
    }

    static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

/// A Gmail label (id → display name).
public struct GmailLabel: Decodable, Sendable {
    public let id: String
    public let name: String
}

/// `labels.list` response envelope.
public struct LabelListResponse: Decodable, Sendable {
    public let labels: [GmailLabel]?
}
