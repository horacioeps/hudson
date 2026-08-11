import Foundation

/// One file attached to an outbound message. `MimeBuilder` base64-encodes
/// `data` into its own MIME part under `multipart/mixed` (spec §7.1).
public struct Attachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// The compose input `MimeBuilder` turns into RFC 5322 bytes. Deliberately
/// a plain value type with no Gmail/network knowledge — `SendService` (a
/// later M5 task) owns assigning the Message-ID and persisting the built
/// MIME; this type only carries what was actually composed (spec §7.1).
public struct OutboxMessage: Sendable, Equatable {
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let bodyText: String
    public let bodyHTML: String?
    public let attachments: [Attachment]
    /// The threading triple's second leg (part one): the parent message's
    /// RFC `Message-ID` header value (e.g. `"<abc@mail.gmail.com>"`), set
    /// only for replies (spec §7.1).
    public let inReplyTo: String?
    /// The threading triple's second leg (part two), ACCUMULATED: the
    /// parent's own `References` chain with the parent's Message-ID
    /// appended — not just the immediate parent — so a deep reply chain
    /// still references the whole thread per RFC 5322 §3.6.4.
    public let references: [String]
    /// The threading triple's first leg: Gmail's own thread id, passed to
    /// `sendRawMessage(_:threadID:)` (not a MIME header). An edited subject
    /// deliberately omits this to start a new Gmail thread even though
    /// `In-Reply-To`/`References` still point back (spec §7.1).
    public let threadID: String?

    public init(
        from: String,
        to: [String],
        cc: [String] = [],
        bcc: [String] = [],
        subject: String,
        bodyText: String,
        bodyHTML: String? = nil,
        attachments: [Attachment] = [],
        inReplyTo: String? = nil,
        references: [String] = [],
        threadID: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.threadID = threadID
    }
}
