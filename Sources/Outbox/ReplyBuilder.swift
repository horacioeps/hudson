import Foundation
import Store

/// `replyMessage` couldn't build the threading triple. The only failure
/// mode is having nothing to reply TO — `Store` reads never throw on a
/// missing row, they just return empty, so this is the one place that has
/// to turn "empty" into an explicit error for a caller that asked to reply
/// to a specific thread.
public enum ReplyBuilderError: Error, Equatable {
    /// `threadID` has no messages in the local Store (wrong id, or a
    /// thread this account never synced).
    case emptyThread(threadID: String)
}

/// Builds the `OutboxMessage` for a reply to an existing thread, assembling
/// spec §7.1's FULL threading triple from what the thread's NEWEST message
/// actually carries — never from caller-supplied guesses:
///
/// 1. **Gmail `threadId`** — passed straight through as `threadID`.
/// 2. **`In-Reply-To`/`References`** — `In-Reply-To` is the newest
///    message's own `Message-ID`; `References` is that message's own
///    `References` chain with its `Message-ID` appended (RFC 5322 §3.6.4),
///    NOT just the immediate parent's id alone — so a deep reply chain
///    still references the whole thread.
/// 3. **A matching Subject** — `SubjectNormalization.replySubject` applied
///    to the newest message's own Subject, collapsing to exactly one
///    `Re: ` however many hops (and however many differently-localized
///    prefixes) came before.
///
/// This function always threads (never omits `threadID`); a caller that
/// lets the user hand-edit the Subject before sending is the one who must
/// decide to drop `threadID` on THAT message to deliberately start a new
/// Gmail thread (spec §7.1) — that's a compose-time UI/CLI decision no
/// pure builder can make on its own, so it's left to the caller.
///
/// A free function (not a `SendService` method) because it only READS the
/// thread and returns a value — no job is enqueued here. The caller still
/// calls `SendService.enqueue(_:)` with the result, exactly as it would for
/// a fresh compose.
public func replyMessage(
    to threadID: String, account: String, database: HudsonDatabase,
    from: String, bodyText: String, bodyHTML: String? = nil, replyAll: Bool
) async throws -> OutboxMessage {
    let messages = try await database.threadMessages(threadID: threadID, account: account)
    // `threadMessages` orders oldest-first, so the newest is the last
    // element — the message this reply is actually replying to.
    guard let newest = messages.last else {
        throw ReplyBuilderError.emptyThread(threadID: threadID)
    }

    let recipients = ReplyRecipients.derive(newest: newest, from: from, replyAll: replyAll)
    let subject = SubjectNormalization.replySubject(from: newest.subject)

    var references = ReplyRecipients.splitReferences(newest.referencesHeader)
    if let parentMessageID = newest.rfc822MessageID {
        references.append(parentMessageID)
    }

    return OutboxMessage(
        from: from, to: recipients.to, cc: recipients.cc, subject: subject,
        bodyText: bodyText, bodyHTML: bodyHTML,
        inReplyTo: newest.rfc822MessageID, references: references, threadID: threadID)
}

/// Recipient derivation for `replyMessage` — pure and total over whatever
/// `From:`/`To:` lines the Store persisted, since those are untrusted
/// sender-controlled header text (mirrors `HudsonUI.SenderInfo`'s own
/// posture; reimplemented here rather than depending on `HudsonUI`, which
/// `Outbox` deliberately doesn't link against).
enum ReplyRecipients {
    /// Plain reply: only the newest message's sender. Reply-all: the
    /// sender PLUS every other address on the newest message's own `To:`
    /// line, minus the replying user's own address (so replying doesn't
    /// re-address yourself).
    ///
    /// **Self-authored newest message:** Sent mail shares the thread's
    /// `thread_id` too, and `threadMessages` doesn't filter by direction —
    /// so the "newest" message can legitimately be a follow-up the
    /// replying user sent themselves (e.g. before the other side
    /// answered), not a message from the correspondent. In that case
    /// `newest.fromLine`'s bare address IS `from`, and blindly addressing
    /// the reply back to "the sender" would silently mail the user their
    /// own inbox and drop the real correspondent (plain reply) or merely
    /// self-CC them alongside the real recipient (reply-all). When that
    /// happens, the target is derived from that self-authored message's
    /// OWN `To:` line (minus self) instead — the same set `otherRecipients`
    /// already computes for the reply-all branch — for both plain reply
    /// and reply-all alike, since there's no sender-distinct-from-To-line
    /// case to make reply-all any wider here.
    ///
    /// **Known gap:** the Store doesn't persist the original message's
    /// `Cc:` header (only `From`/`To` — see `messages` table, v1), so
    /// reply-all's `cc` is always empty here even when the original had
    /// Cc'd recipients who arguably belong back on this reply. Left as a
    /// documented gap rather than adding `cc_line` persistence, which is
    /// out of Task 5's scope (see the M5 plan's Task 5 note on this seam);
    /// a follow-up carry-forward can add it the same way `has_attachment`
    /// was added in migration v4.
    static func derive(newest: MessageRow, from: String, replyAll: Bool) -> (to: [String], cc: [String]) {
        let selfAddress = bareAddress(from).lowercased()
        let senderAddress = bareAddress(newest.fromLine)
        let otherRecipients = splitAddressList(newest.toLine)
            .map(bareAddress)
            .filter { !$0.isEmpty && $0.lowercased() != selfAddress }

        guard senderAddress.lowercased() != selfAddress else {
            return (dedupCaseInsensitive(otherRecipients), [])
        }

        guard replyAll else { return (dedupCaseInsensitive([senderAddress]), []) }
        return (dedupCaseInsensitive([senderAddress] + otherRecipients), [])
    }

    /// The stored `References` header, split back into individual `<id>`
    /// tokens on whitespace (how it was joined both by Gmail on the wire
    /// and by `MimeBuilder.topHeaders` on the way back out) — `nil`/empty
    /// input yields `[]`, the correct starting point for a reply to a
    /// thread ROOT message (which has no `References` of its own).
    static func splitReferences(_ header: String?) -> [String] {
        guard let header else { return [] }
        return header.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Splits a comma-separated RFC 5322 address list into individual
    /// entries, treating a comma as a separator only OUTSIDE any
    /// `<...>`/`"..."` span — a naive `.split(",")` would wrongly cut a
    /// quoted display name containing a comma in two (e.g.
    /// `"Doe, Jane" <jane@x.com>, bob@y.com`).
    static func splitAddressList(_ line: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var insideAngleBrackets = false
        var insideQuotes = false
        for character in line {
            switch character {
            case "\"":
                insideQuotes.toggle()
                current.append(character)
            case "<" where !insideQuotes:
                insideAngleBrackets = true
                current.append(character)
            case ">" where !insideQuotes:
                insideAngleBrackets = false
                current.append(character)
            case "," where !insideAngleBrackets && !insideQuotes:
                entries.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { entries.append(last) }
        return entries.filter { !$0.isEmpty }
    }

    /// The bare `user@domain` inside a `Name <user@domain>` entry, or the
    /// entry itself when there's no `<...>` to extract from. Matches
    /// `HudsonUI.SenderInfo.address(fromLine:)`'s exact behavior.
    static func bareAddress(_ entry: String) -> String {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close
        else { return trimmed }
        return String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Case-insensitive de-dup that preserves first-seen order and drops
    /// blanks — used so a reply-all whose sender also happens to appear on
    /// the To line (a common real-world pattern) doesn't address them
    /// twice.
    static func dedupCaseInsensitive(_ addresses: [String]) -> [String] {
        var seenLowercased = Set<String>()
        var result: [String] = []
        for address in addresses {
            let key = address.lowercased()
            guard !key.isEmpty, !seenLowercased.contains(key) else { continue }
            seenLowercased.insert(key)
            result.append(address)
        }
        return result
    }
}
