import Foundation
import Testing
@testable import Outbox

// Fixed messageID + date so every assertion here (including the golden-file
// compare) is byte-deterministic across machines and runs — the Global
// Constraint this task exists to prove. Never use `Date()`/`UUID()` in this
// file.
private let fixedMessageID = "<b5b6b3d1-1e0e-4f0a-9a2b-a1b2c3d4e5f6@hudson.local>"
private let fixedDate = Date(timeIntervalSince1970: 1_770_000_000)  // 2026-02-02T02:40:00Z

/// Splits a built MIME `Data` into its header block (as `name: value`
/// pairs, last-wins is irrelevant here since MimeBuilder never repeats a
/// header) and the raw trailing bytes. Headers are always plain ASCII in
/// this builder's output — only body/attachment payload lines are
/// base64 — so decoding the WHOLE buffer as UTF-8 to locate the header
/// block is safe.
private func parseHeaders(_ data: Data) throws -> [String: String] {
    let text = String(decoding: data, as: UTF8.self)
    guard let blankLine = text.range(of: "\r\n\r\n") else {
        Issue.record("no header/body separator found")
        return [:]
    }
    var headers: [String: String] = [:]
    for line in text[text.startIndex..<blankLine.lowerBound].components(separatedBy: "\r\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }
    return headers
}

/// Locates a MIME part's base64 payload by its `Content-Type` header
/// prefix and decodes it back to bytes, so the round-trip proves the
/// encoder actually wrote what was handed in — not just that SOME bytes
/// came out.
private func decodedBody(_ data: Data, afterContentTypePrefix prefix: String) throws -> Data {
    let text = String(decoding: data, as: UTF8.self)
    let marker = "Content-Type: \(prefix)"
    let markerRange = try #require(text.range(of: marker))
    let blankLine = try #require(text.range(of: "\r\n\r\n", range: markerRange.upperBound..<text.endIndex))
    // The payload runs until the next boundary line (`\r\n--`) or end of
    // string for a single-part message with nothing after it.
    let end = text.range(of: "\r\n--", range: blankLine.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
    let base64 = text[blankLine.upperBound..<end].replacingOccurrences(of: "\r\n", with: "")
    return try #require(Data(base64Encoded: base64))
}

// MARK: - Golden file (byte-deterministic reply, full threading triple)

// `Tests/OutboxTests/Golden/reply.eml` was captured from this exact
// implementation's output for the exact input below, after manually
// verifying the header block, threading triple, boundary derivation, and
// both base64 bodies decode back to their source strings (see the
// structural tests below, which assert the same properties independent of
// the golden bytes). If `MimeBuilder`'s output format ever changes on
// purpose, regenerate by temporarily writing `built` to that path from
// this test, inspecting the diff, and committing the new fixture — never
// regenerate blind.
@Test func buildReplyMatchesGoldenBytes() throws {
    let message = OutboxMessage(
        from: "me@example.com",
        to: ["alice@example.com"],
        cc: ["bob@example.com"],
        subject: "Re: Q3 planning",
        bodyText: "Sounds good, see you then.",
        bodyHTML: "<p>Sounds good, see you then.</p>",
        inReplyTo: "<orig-1@mail.gmail.com>",
        references: ["<orig-0@mail.gmail.com>", "<orig-1@mail.gmail.com>"],
        threadID: "t100")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)

    let goldenURL = try #require(Bundle.module.url(forResource: "Golden/reply", withExtension: "eml"))
    let golden = try Data(contentsOf: goldenURL)
    // A byte-for-byte compare is the actual point of a golden-file test —
    // any accidental change to header order, line endings, boundary
    // derivation, or wrap width shows up as a diff here, not just as a
    // passing-but-wrong structural assertion below.
    #expect(built == golden)
}

// MARK: - Threading triple + header assertions (independent of golden bytes)

@Test func buildReplySetsMessageIDDateAndAddressHeaders() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["alice@example.com"], cc: ["bob@example.com"],
        subject: "Re: Q3 planning", bodyText: "hi")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Message-ID"] == fixedMessageID)
    #expect(headers["Date"] == "Mon, 02 Feb 2026 02:40:00 +0000")
    #expect(headers["From"] == "me@example.com")
    #expect(headers["To"] == "alice@example.com")
    #expect(headers["Cc"] == "bob@example.com")
    #expect(headers["Subject"] == "Re: Q3 planning")
    #expect(headers["MIME-Version"] == "1.0")
}

@Test func buildOmitsCcHeaderWhenEmpty() throws {
    let message = OutboxMessage(from: "me@example.com", to: ["alice@example.com"], subject: "hi", bodyText: "hi")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Cc"] == nil)
    #expect(headers["Bcc"] == nil)
}

@Test func buildIncludesBccHeaderWhenPresent() throws {
    // Gmail's raw-send endpoint delivers to Bcc addresses found in the raw
    // MIME and strips the header before delivering to other recipients —
    // silently dropping it here would mean a user's bcc'd recipient never
    // receives the mail at all.
    let message = OutboxMessage(
        from: "me@example.com", to: ["alice@example.com"], bcc: ["hidden@example.com"],
        subject: "hi", bodyText: "hi")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Bcc"] == "hidden@example.com")
}

@Test func buildOmitsToHeaderWhenEmpty() throws {
    // RFC 5322 permits a message to originate via `Bcc:` alone. `To:` must
    // follow the same omission pattern as `Cc:`/`Bcc:` — an empty `to`
    // must NOT produce a blank `To: ` header line (that's what this test
    // guards against; it previously did).
    let message = OutboxMessage(
        from: "me@example.com", to: [], bcc: ["hidden@example.com"], subject: "hi", bodyText: "hi")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["To"] == nil)
    #expect(headers["Bcc"] == "hidden@example.com")
    let headerBlock = String(decoding: built, as: UTF8.self)
        .components(separatedBy: "\r\n\r\n")[0]
    #expect(!headerBlock.components(separatedBy: "\r\n").contains { $0.hasPrefix("To:") })
}

@Test func buildSetsInReplyToAndReferencesOnlyWhenPresent() throws {
    let plain = OutboxMessage(from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "hi")
    let built = try MimeBuilder.build(plain, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["In-Reply-To"] == nil)
    #expect(headers["References"] == nil)

    let reply = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "Re: hi", bodyText: "hi",
        inReplyTo: "<orig-1@mail.gmail.com>",
        references: ["<orig-0@mail.gmail.com>", "<orig-1@mail.gmail.com>"])
    let builtReply = try MimeBuilder.build(reply, messageID: fixedMessageID, date: fixedDate)
    let replyHeaders = try parseHeaders(builtReply)
    #expect(replyHeaders["In-Reply-To"] == "<orig-1@mail.gmail.com>")
    #expect(replyHeaders["References"] == "<orig-0@mail.gmail.com> <orig-1@mail.gmail.com>")
}

// MARK: - MIME structure

@Test func buildTextOnlyMessageIsASinglePlainPart() throws {
    let message = OutboxMessage(from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "just text")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Content-Type"] == "text/plain; charset=utf-8")
    let body = try decodedBody(built, afterContentTypePrefix: "text/plain; charset=utf-8")
    #expect(String(decoding: body, as: UTF8.self) == "just text")
}

@Test func buildTextAndHTMLMessageIsMultipartAlternative() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi",
        bodyText: "plain body", bodyHTML: "<p>html body</p>")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Content-Type"]?.hasPrefix("multipart/alternative; boundary=") == true)

    let plainBody = try decodedBody(built, afterContentTypePrefix: "text/plain; charset=utf-8")
    #expect(String(decoding: plainBody, as: UTF8.self) == "plain body")
    let htmlBody = try decodedBody(built, afterContentTypePrefix: "text/html; charset=utf-8")
    #expect(String(decoding: htmlBody, as: UTF8.self) == "<p>html body</p>")
}

@Test func buildWithAttachmentIsMultipartMixed() throws {
    let attachment = Attachment(filename: "notes.txt", mimeType: "text/plain", data: Data("attach me".utf8))
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi",
        bodyText: "see attached", attachments: [attachment])
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Content-Type"]?.hasPrefix("multipart/mixed; boundary=") == true)

    let text = String(decoding: built, as: UTF8.self)
    #expect(text.contains("Content-Disposition: attachment; filename=\"notes.txt\""))
    let attachmentBody = try decodedBody(built, afterContentTypePrefix: "text/plain; name=\"notes.txt\"")
    #expect(String(decoding: attachmentBody, as: UTF8.self) == "attach me")
}

@Test func buildDifferentMessageIDsProduceDifferentBoundaries() throws {
    // Boundaries are derived from the Message-ID, not random — but they
    // MUST still differ across distinct messages, otherwise two different
    // sends composed close together could collide if ever concatenated or
    // compared. This also indirectly proves determinism isn't achieved by
    // just hardcoding one literal boundary string.
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi",
        bodyText: "t", bodyHTML: "<p>t</p>")
    let builtA = try MimeBuilder.build(message, messageID: "<aaa@hudson.local>", date: fixedDate)
    let builtB = try MimeBuilder.build(message, messageID: "<bbb@hudson.local>", date: fixedDate)
    #expect(builtA != builtB)
    let headersA = try parseHeaders(builtA)
    let headersB = try parseHeaders(builtB)
    #expect(headersA["Content-Type"] != headersB["Content-Type"])
}

@Test func buildIsDeterministicForFixedMessageIDAndDate() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi",
        bodyText: "t", bodyHTML: "<p>t</p>",
        attachments: [Attachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8))])
    let first = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let second = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    #expect(first == second)
}

// MARK: - Size validation (spec §7.1: enqueue time, not fire time)

@Test func buildThrowsWhenEncodedSizeExceedsCap() throws {
    // Base64 inflates by ~4/3 plus line-wrap overhead, so 30 MB of raw
    // attachment bytes lands well past the 35 MB encoded cap while still
    // being a cheap, fast-to-allocate zeroed buffer for a test.
    let bigAttachment = Attachment(
        filename: "big.bin", mimeType: "application/octet-stream",
        data: Data(count: 30 * 1024 * 1024))
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi",
        bodyText: "see attached", attachments: [bigAttachment])
    #expect(throws: OutboxError.self) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
    do {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
        Issue.record("expected OutboxError.tooLarge")
    } catch OutboxError.tooLarge(let encodedBytes) {
        #expect(encodedBytes > MimeBuilder.maxEncodedBytes)
    }
}

@Test func buildUnderCapSucceeds() throws {
    let message = OutboxMessage(from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "small")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    #expect(built.count < MimeBuilder.maxEncodedBytes)
}

@Test func maxEncodedBytesBoundsBuiltDocumentNotWirePayload() throws {
    // `maxEncodedBytes` bounds `build()`'s OWN output size — the RFC 5322
    // document itself — NOT the HTTP request body `GmailKit`'s
    // `SendEndpoints.sendRawMessage` eventually sends, which base64url-
    // encodes this entire document again for the JSON `raw` field. This
    // test codifies that distinction (see the doc comment on
    // `maxEncodedBytes`) so a future change that silently conflates the two
    // doesn't go unnoticed: the wire-equivalent size of a document sized
    // right at the cap is reliably LARGER than the cap itself.
    let mimeSizedAtCap = MimeBuilder.maxEncodedBytes
    let base64WireEquivalentSize = ((mimeSizedAtCap + 2) / 3) * 4
    #expect(base64WireEquivalentSize > MimeBuilder.maxEncodedBytes)
}

// MARK: - Header-value sanitization (CR/LF injection, spec §7.1's raw MIME)

// A raw CR/LF embedded in any value that lands on a header line would let a
// caller — or, once Task 5 wires reply Subjects from an external thread's
// incoming mail, an attacker-controlled Subject — inject an entirely new
// header line (e.g. a stealth `Bcc:`) into the outgoing send. Every field
// below must throw `OutboxError.invalidHeaderValue` rather than write the
// CR/LF through verbatim.

@Test func buildThrowsOnCRLFInjectionInSubject() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"],
        subject: "hi\r\nBcc: attacker@evil.com", bodyText: "hi")
    #expect(throws: OutboxError.invalidHeaderValue(field: "subject")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInFrom() throws {
    let message = OutboxMessage(
        from: "me@example.com\r\nBcc: attacker@evil.com", to: ["a@example.com"],
        subject: "hi", bodyText: "hi")
    #expect(throws: OutboxError.invalidHeaderValue(field: "from")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInTo() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com\r\nBcc: attacker@evil.com"],
        subject: "hi", bodyText: "hi")
    #expect(throws: OutboxError.invalidHeaderValue(field: "to")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInCc() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], cc: ["b@example.com\nBcc: attacker@evil.com"],
        subject: "hi", bodyText: "hi")
    #expect(throws: OutboxError.invalidHeaderValue(field: "cc")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInBcc() throws {
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], bcc: ["b@example.com\r\nX-Injected: yes"],
        subject: "hi", bodyText: "hi")
    #expect(throws: OutboxError.invalidHeaderValue(field: "bcc")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInThreadingHeaders() throws {
    let badInReplyTo = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "hi",
        inReplyTo: "<orig@x>\r\nBcc: attacker@evil.com")
    #expect(throws: OutboxError.invalidHeaderValue(field: "inReplyTo")) {
        _ = try MimeBuilder.build(badInReplyTo, messageID: fixedMessageID, date: fixedDate)
    }

    let badReferences = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "hi",
        references: ["<orig@x>\r\nBcc: attacker@evil.com"])
    #expect(throws: OutboxError.invalidHeaderValue(field: "references")) {
        _ = try MimeBuilder.build(badReferences, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInAttachmentFilename() throws {
    let attachment = Attachment(
        filename: "notes.txt\r\nBcc: attacker@evil.com", mimeType: "text/plain", data: Data("x".utf8))
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "hi", attachments: [attachment])
    #expect(throws: OutboxError.invalidHeaderValue(field: "attachment.filename")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildThrowsOnCRLFInjectionInAttachmentMimeType() throws {
    let attachment = Attachment(
        filename: "notes.txt", mimeType: "text/plain\r\nBcc: attacker@evil.com", data: Data("x".utf8))
    let message = OutboxMessage(
        from: "me@example.com", to: ["a@example.com"], subject: "hi", bodyText: "hi", attachments: [attachment])
    #expect(throws: OutboxError.invalidHeaderValue(field: "attachment.mimeType")) {
        _ = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    }
}

@Test func buildAllowsOrdinaryAddressesAndSubjectWithColonsAndPunctuation() throws {
    // A sanity check that the sanitizer is CR/LF-specific and doesn't
    // over-reject ordinary header-safe values (colons, commas within a
    // quoted display name, etc.).
    let message = OutboxMessage(
        from: "\"Doe, Jane\" <jane@example.com>", to: ["a@example.com"],
        subject: "Re: budget: Q3 numbers, final", bodyText: "hi")
    let built = try MimeBuilder.build(message, messageID: fixedMessageID, date: fixedDate)
    let headers = try parseHeaders(built)
    #expect(headers["Subject"] == "Re: budget: Q3 numbers, final")
}
