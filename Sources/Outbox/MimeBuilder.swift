import CryptoKit
import Foundation

/// Errors the MIME builder can raise. Size is validated at
/// compose/enqueue time (never at scheduler fire time — spec §7.1), so a
/// caller building an `OutboxMessage` finds out about an oversized
/// attachment while the user is still looking at the compose window.
public enum OutboxError: Error, Equatable {
    /// The fully built MIME payload exceeded `MimeBuilder.maxEncodedBytes`.
    case tooLarge(encodedBytes: Int)
    /// A value destined for a single header line (Subject/From/To/Cc/Bcc/
    /// In-Reply-To/References/attachment filename/mimeType) contained a raw
    /// CR or LF. Thrown at build time — the same "catch it at compose/
    /// enqueue time, not later" posture as `tooLarge` — because an embedded
    /// newline there is not inert text: this builder writes header lines
    /// without any folding support, so a CR/LF inside a value does not
    /// become a continuation of the SAME header, it starts an entirely NEW
    /// header line the caller never asked for (e.g. a stealth `Bcc:`).
    /// `field` names which value failed, for a caller-facing error message.
    case invalidHeaderValue(field: String)
}

/// Builds RFC 5322 messages from an `OutboxMessage` (spec §7.1):
/// `text/plain` + `text/html` as `multipart/alternative`, attachments
/// wrapping that in `multipart/mixed`, and — when present — the
/// `In-Reply-To`/`References` legs of the threading triple. (The third leg,
/// Gmail's `threadId`, is not an RFC header at all — it rides on
/// `OutboxMessage.threadID` for the caller to pass separately to
/// `sendRawMessage(_:threadID:)`.)
///
/// Output is BYTE-DETERMINISTIC for a fixed `messageID` + `date`: no
/// `Date()`, no `UUID()`, no random boundary strings anywhere in here —
/// MIME part boundaries are derived from `messageID` via SHA-256 instead of
/// `UUID()`, which is what makes the golden-file tests viable at all (a
/// nondeterministic boundary would make every build produce different
/// bytes even for identical input, defeating a byte-compare test).
public enum MimeBuilder {
    /// The 35 MB MIME cap from spec §7.1 (~25 MB effective attachments
    /// after base64 inflation). Measured against the FULLY built message
    /// `build()` returns — headers + MIME structure + the already-base64
    /// bodies/attachments — which is what Gmail's documented message-size
    /// limit is actually about (the email itself, not any one particular
    /// wire encoding of it).
    ///
    /// This is deliberately NOT the same byte count as the HTTP request
    /// body `GmailKit`'s `SendEndpoints.sendRawMessage` ends up sending:
    /// that call base64url-encodes THIS WHOLE DOCUMENT AGAIN to populate
    /// the JSON `raw` field, so the actual wire payload runs roughly 4/3
    /// the size checked here (a message built at, say, 34 MB produces a
    /// ~45 MB request body). That inflation is an artifact of the JSON
    /// transport Gmail's API happens to use for `messages.send`, not
    /// additional message content, so bounding the wire-transport size
    /// HERE instead would shrink the effective attachment allowance well
    /// below the ~25 MB spec §7.1 promises — see
    /// `maxEncodedBytesBoundsBuiltDocumentNotWirePayload` in
    /// `MimeBuilderTests.swift` for the codified version of this
    /// distinction.
    public static let maxEncodedBytes = 35 * 1024 * 1024

    public static func build(_ message: OutboxMessage, messageID: String, date: Date) throws -> Data {
        let altBoundary = boundary(seed: messageID, purpose: "alt")
        let mixedBoundary = boundary(seed: messageID, purpose: "mixed")

        let bodyPart = bodyContentBlock(message, altBoundary: altBoundary)
        let contentBlock: Data
        if message.attachments.isEmpty {
            contentBlock = bodyPart
        } else {
            let attachmentParts = try message.attachments.map(attachmentPart)
            contentBlock = renderMultipart(
                type: "multipart/mixed", boundary: mixedBoundary, parts: [bodyPart] + attachmentParts)
        }

        var mime = try topHeaders(message, messageID: messageID, date: date)
        mime.append(contentBlock)

        guard mime.count <= maxEncodedBytes else {
            throw OutboxError.tooLarge(encodedBytes: mime.count)
        }
        return mime
    }

    // MARK: - Top-level headers

    /// The message-level headers that sit ABOVE the MIME structure:
    /// `Message-ID`/`Date`/`From`/`To`/`Cc`/`Bcc`/`Subject`/threading pair,
    /// then `MIME-Version` as the last line before the content block's own
    /// `Content-Type` header picks up. Address/threading headers that are
    /// empty on the input are omitted entirely, not written blank — an
    /// empty `Cc:`/`To:` header is a needless artifact some mail parsers
    /// treat oddly (RFC 5322 permits a message to originate via `Bcc:`
    /// alone), and a bare `In-Reply-To:`/`References:` with nothing after
    /// it would actively lie about this being a reply.
    ///
    /// Every value here is passed through `requireHeaderSafe` first: these
    /// are all attacker-reachable in the general case (Task 5 wires reply
    /// Subjects from an external thread's incoming mail; From/To/Cc/Bcc
    /// come straight from the compose caller), so a raw CR/LF anywhere in
    /// them must fail the build rather than silently inject an extra
    /// header line into the raw MIME.
    private static func topHeaders(_ message: OutboxMessage, messageID: String, date: Date) throws -> Data {
        var lines: [String] = []
        lines.append("Message-ID: \(messageID)")
        lines.append("Date: \(rfc2822(date))")
        lines.append("From: \(try requireHeaderSafe(message.from, field: "from"))")
        if !message.to.isEmpty {
            lines.append("To: \(try requireHeaderSafe(message.to.joined(separator: ", "), field: "to"))")
        }
        if !message.cc.isEmpty {
            lines.append("Cc: \(try requireHeaderSafe(message.cc.joined(separator: ", "), field: "cc"))")
        }
        // Gmail's raw-send endpoint reads Bcc out of the raw MIME and
        // strips it before delivering to other recipients — omitting this
        // header would mean bcc'd recipients silently never receive the
        // mail at all, not just that they're visible to others.
        if !message.bcc.isEmpty {
            lines.append("Bcc: \(try requireHeaderSafe(message.bcc.joined(separator: ", "), field: "bcc"))")
        }
        lines.append("Subject: \(try requireHeaderSafe(message.subject, field: "subject"))")
        if let inReplyTo = message.inReplyTo {
            lines.append("In-Reply-To: \(try requireHeaderSafe(inReplyTo, field: "inReplyTo"))")
        }
        if !message.references.isEmpty {
            let references = try requireHeaderSafe(
                message.references.joined(separator: " "), field: "references")
            lines.append("References: \(references)")
        }
        lines.append("MIME-Version: 1.0")
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// Rejects (rather than silently stripping) any header-destined value
    /// containing a raw CR or LF — see `OutboxError.invalidHeaderValue` for
    /// why this must throw instead of quietly sanitizing.
    ///
    /// Checks `unicodeScalars`, NOT `Character`-level `contains`: Swift's
    /// `String` treats a CR immediately followed by LF as a SINGLE extended
    /// grapheme cluster, so `"hi\r\nBcc: x".contains("\r")` — and
    /// `.contains("\n")` — both evaluate to `false` (neither a bare `"\r"`
    /// nor a bare `"\n"` Character occurs in that string; only the combined
    /// `"\r\n"` Character does). Scanning Unicode scalars sidesteps
    /// grapheme clustering entirely and reliably catches CR and LF whether
    /// they appear alone or paired.
    private static func requireHeaderSafe(_ value: String, field: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
            throw OutboxError.invalidHeaderValue(field: field)
        }
        return value
    }

    /// RFC 5322 §3.3 date-time, formatted in a FIXED locale/timezone
    /// (POSIX/GMT) rather than the host's — otherwise the exact same
    /// `Date` value would render different bytes on a machine in Tokyo
    /// than one in New York, silently breaking byte-determinism for
    /// anyone running the golden-file tests outside the author's timezone.
    private static func rfc2822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: - Body structure

    /// The `text/plain` (+ optional `text/html` as `multipart/alternative`)
    /// portion, returned as a self-contained header+body block that either
    /// becomes the WHOLE content block (no attachments) or gets embedded
    /// as the first part of an outer `multipart/mixed` (attachments
    /// present) — `renderMultipart`'s output is deliberately shaped so it
    /// can be nested either way without the caller caring which.
    private static func bodyContentBlock(_ message: OutboxMessage, altBoundary: String) -> Data {
        let plainPart = leafPart(
            contentType: "text/plain; charset=utf-8", rawBytes: Data(message.bodyText.utf8))
        guard let html = message.bodyHTML else { return plainPart }
        let htmlPart = leafPart(contentType: "text/html; charset=utf-8", rawBytes: Data(html.utf8))
        return renderMultipart(type: "multipart/alternative", boundary: altBoundary, parts: [plainPart, htmlPart])
    }

    private static func attachmentPart(_ attachment: Attachment) throws -> Data {
        // filename/mimeType land in a header line just like the top-level
        // address headers do — same CR/LF injection risk, same fix.
        let mimeType = try requireHeaderSafe(attachment.mimeType, field: "attachment.mimeType")
        let filename = try requireHeaderSafe(attachment.filename, field: "attachment.filename")
        return leafPart(
            contentType: "\(mimeType); name=\"\(filename)\"",
            extraHeaders: ["Content-Disposition: attachment; filename=\"\(filename)\""],
            rawBytes: attachment.data)
    }

    /// One non-multipart MIME part: its own `Content-Type` (+ any extra
    /// headers, e.g. `Content-Disposition`), always `Content-Transfer-Encoding:
    /// base64` — chosen uniformly for EVERY part (text included), not just
    /// binary attachments, so there is exactly one encoding code path to
    /// get right instead of two (base64 for attachments, quoted-printable
    /// for text) with their own separate edge cases around line-folding
    /// and non-ASCII bytes. Returned WITHOUT a trailing boundary line —
    /// `renderMultipart` owns boundary placement, and the top-level
    /// no-attachment/no-html case uses this block as-is with nothing after
    /// it.
    private static func leafPart(contentType: String, extraHeaders: [String] = [], rawBytes: Data) -> Data {
        var headerText = "Content-Type: \(contentType)\r\n"
        for header in extraHeaders { headerText += "\(header)\r\n" }
        headerText += "Content-Transfer-Encoding: base64\r\n\r\n"
        var out = Data(headerText.utf8)
        out.append(Data(base64Wrapped(rawBytes).utf8))
        return out
    }

    /// Wraps a multipart container's `Content-Type: <type>; boundary="…"`
    /// header around already-rendered `parts`, each preceded by its own
    /// `--boundary` delimiter line and the whole thing closed with the
    /// `--boundary--` terminator (RFC 2046 §5.1.1). The result is itself a
    /// valid header+body block, so it can be handed straight to `build` as
    /// the top-level content block OR passed to a further `renderMultipart`
    /// call as one more `parts` entry (that's exactly how attachments wrap
    /// the alternative part in `multipart/mixed`).
    private static func renderMultipart(type: String, boundary: String, parts: [Data]) -> Data {
        var out = Data("Content-Type: \(type); boundary=\"\(boundary)\"\r\n\r\n".utf8)
        for part in parts {
            out.append(Data("--\(boundary)\r\n".utf8))
            out.append(part)
            out.append(Data("\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }

    /// Base64, hard-wrapped at 76 characters per line (RFC 2045 §6.8) with
    /// CRLF — required so the encoded body stays within the line-length
    /// limits mail infrastructure historically enforces, even though this
    /// specific message only ever travels inside a JSON field to Gmail's
    /// API and never through raw SMTP.
    private static func base64Wrapped(_ data: Data) -> String {
        let full = data.base64EncodedString()
        guard !full.isEmpty else { return "" }
        var lines: [String] = []
        var index = full.startIndex
        while index < full.endIndex {
            let end = full.index(index, offsetBy: 76, limitedBy: full.endIndex) ?? full.endIndex
            lines.append(String(full[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    /// Derives a MIME boundary deterministically from the message id
    /// rather than `UUID()`/randomness — the ONLY thing that makes a
    /// golden-file byte-compare of `build`'s output viable across runs.
    /// SHA-256 (not, say, `messageID.hashValue`) is used purely for a
    /// long, low-collision, boundary-charset-safe string: `messageID`
    /// itself contains `<`/`>`/`@`, none of which are legal MIME boundary
    /// characters (RFC 2046 §5.1.1's `bchars`), so it can't be used
    /// verbatim. `purpose` ("alt" vs "mixed") keeps the two boundaries used
    /// in one message from ever colliding with each other.
    private static func boundary(seed: String, purpose: String) -> String {
        let digest = SHA256.hash(data: Data("\(seed)|\(purpose)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "hudson-\(purpose)-\(hex.prefix(16))"
    }
}
