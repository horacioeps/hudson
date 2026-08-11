import Foundation
import GmailKit
@testable import SyncEngine

/// One recorded `listHistory` call — lets tests assert exactly what
/// startHistoryID/pageToken pair each page of a multi-page poll was called
/// with (regression coverage for the fix that keeps startHistoryID fixed
/// across pagination; see HistoryTests).
struct HistoryCall: Equatable {
    let startHistoryID: String
    let pageToken: String?
}

/// One recorded `modify` call — lets flusher tests assert exactly which
/// message and label delta was sent (and that a batchable set was NOT
/// double-sent through the singleton path).
struct ModifyCall: Equatable {
    let id: String
    let addLabelIDs: [String]
    let removeLabelIDs: [String]
}

/// One recorded `batchModify` call — lets flusher tests assert coalescing
/// (one call covering every message sharing a label delta, not N modifies).
struct BatchModifyCall: Equatable {
    let ids: [String]
    let addLabelIDs: [String]
    let removeLabelIDs: [String]
}

/// A scripted `modify` response — only `historyId` matters to the flusher
/// (it's the retirement gate); everything else round-trips through
/// `testMessage`'s placeholders.
struct GmailMessageStub {
    let id: String
    let historyId: String
}

/// Scriptable in-memory Gmail for SyncEngine tests: serves canned list pages,
/// messages, and history pages; records every call.
actor ScriptedGmail: GmailAPI {
    var profile: Profile
    var listPages: [MessageListPage]
    var messagesByID: [String: GmailMessage]
    var historyPages: [HistoryPage]
    /// When set, listHistory throws this (e.g. 404 expiry) instead of serving.
    var historyError: GmailError?
    /// Scripted `modify` response — see `GmailMessageStub`. Defaults to
    /// echoing the requested id with historyId "100" when unset. Applies to
    /// every id that doesn't have its own entry in `modifyResultsByID`.
    var modifyResult: GmailMessageStub?
    /// When set, `modify` throws this instead of serving `modifyResult`.
    /// Applies to every id that doesn't have its own entry in
    /// `modifyErrorsByID`.
    var modifyError: GmailError?
    /// Per-id override of `modifyResult` — lets a test script one id's
    /// `modify` to succeed while another's fails (isolation-retry tests).
    var modifyResultsByID: [String: GmailMessageStub] = [:]
    /// Per-id override of `modifyError` — checked before the blanket
    /// `modifyError`.
    var modifyErrorsByID: [String: GmailError] = [:]
    /// When set, `batchModify` throws this instead of succeeding (204).
    var batchModifyError: GmailError?
    private(set) var calls: [String] = []
    /// Every `listHistory` call, in order — see `HistoryCall`.
    private(set) var historyCalls: [HistoryCall] = []
    /// Every `modify` call, in order — see `ModifyCall`.
    private(set) var modifyCalls: [ModifyCall] = []
    /// Every `batchModify` call, in order — see `BatchModifyCall`.
    private(set) var batchModifyCalls: [BatchModifyCall] = []

    init(
        profile: Profile = Profile(
            emailAddress: "x", messagesTotal: 0, threadsTotal: 0, historyId: "100"),
        listPages: [MessageListPage] = [],
        messagesByID: [String: GmailMessage] = [:],
        historyPages: [HistoryPage] = []
    ) {
        self.profile = profile
        self.listPages = listPages
        self.messagesByID = messagesByID
        self.historyPages = historyPages
    }

    func getProfile() async throws -> Profile {
        calls.append("profile")
        return profile
    }

    func listMessages(pageToken: String?, maxResults: Int) async throws -> MessageListPage {
        calls.append("list:\(pageToken ?? "start")")
        guard !listPages.isEmpty else {
            return MessageListPage(messages: [], nextPageToken: nil, resultSizeEstimate: 0)
        }
        return listPages.removeFirst()
    }

    func getMessage(id: String, format: String) async throws -> GmailMessage {
        calls.append("get:\(id):\(format)")
        guard let message = messagesByID[id] else {
            throw GmailError.invalidRequest(status: 404, message: "no message \(id)")
        }
        return message
    }

    func listHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        calls.append("history:\(startHistoryID)")
        historyCalls.append(HistoryCall(startHistoryID: startHistoryID, pageToken: pageToken))
        if let historyError { throw historyError }
        guard !historyPages.isEmpty else {
            return HistoryPage(history: nil, nextPageToken: nil, historyId: startHistoryID)
        }
        return historyPages.removeFirst()
    }

    func listLabels() async throws -> [GmailLabel] {
        calls.append("labels")
        return []
    }

    func modify(id: String, addLabelIDs: [String], removeLabelIDs: [String]) async throws -> GmailMessage {
        calls.append("modify:\(id)")
        modifyCalls.append(ModifyCall(id: id, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs))
        if let error = modifyErrorsByID[id] ?? modifyError { throw error }
        let stub = modifyResultsByID[id] ?? modifyResult ?? GmailMessageStub(id: id, historyId: "100")
        return testMessage(id: stub.id, historyID: stub.historyId)
    }

    func batchModify(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws {
        calls.append("batchModify:\(ids.count)")
        batchModifyCalls.append(
            BatchModifyCall(ids: ids, addLabelIDs: addLabelIDs, removeLabelIDs: removeLabelIDs))
        if let batchModifyError { throw batchModifyError }
    }

    func setHistoryError(_ error: GmailError?) { historyError = error }

    func setHistory(_ pages: [HistoryPage]) { historyPages = pages }
    func setMessages(_ messages: [String: GmailMessage]) {
        messagesByID.merge(messages) { _, new in new }
    }
    func setProfileHistoryID(_ id: String) {
        profile = Profile(
            emailAddress: profile.emailAddress, messagesTotal: profile.messagesTotal,
            threadsTotal: profile.threadsTotal, historyId: id)
    }
    func setModifyResult(_ stub: GmailMessageStub) { modifyResult = stub }
    func setModifyError(_ error: GmailError?) { modifyError = error }
    /// Scripts `modify` for exactly one id — for tests that isolate a
    /// coalesced batch's members and need each to answer independently.
    func setModifyResult(_ stub: GmailMessageStub, forID id: String) { modifyResultsByID[id] = stub }
    func setModifyError(_ error: GmailError?, forID id: String) { modifyErrorsByID[id] = error }
    func setBatchModifyError(_ error: GmailError?) { batchModifyError = error }
}

/// Decodes a canned `history.list` page response for tests.
func historyPage(_ json: String) -> HistoryPage {
    try! JSONDecoder().decode(HistoryPage.self, from: Data(json.utf8))
}

/// Builds a metadata-format GmailMessage for tests. `messageID`/`references`
/// (M5 Task 5) optionally add a `Message-ID`/`References` header — omitted
/// from the payload entirely when `nil`, so every pre-existing call site
/// (which doesn't pass them) round-trips through `GmailMessage.header(...)`
/// exactly as before.
func testMessage(
    id: String, threadID: String = "t1", historyID: String, internalDate: String = "1000",
    labels: [String] = ["INBOX"], subject: String = "s",
    messageID: String? = nil, references: String? = nil
) -> GmailMessage {
    // Decodable structs: round-trip through JSON to construct. Building the
    // `labelIds` array manually (not via `\(labels)` string interpolation,
    // whose Array<String>.description re-quotes each already-quoted element
    // into literal `\"INBOX\"` text) keeps the round-trip lossless.
    let labelIDsJSON = "[\(labels.map { "\"\($0)\"" }.joined(separator: ", "))]"
    var headersJSON = """
        {"name": "From", "value": "a@ex.com"}, {"name": "To", "value": "b@ex.com"}, \
        {"name": "Subject", "value": "\(subject)"}
        """
    if let messageID { headersJSON += ", {\"name\": \"Message-ID\", \"value\": \"\(messageID)\"}" }
    if let references { headersJSON += ", {\"name\": \"References\", \"value\": \"\(references)\"}" }
    let json = """
        {"id": "\(id)", "threadId": "\(threadID)", "historyId": "\(historyID)",
         "internalDate": "\(internalDate)", "labelIds": \(labelIDsJSON),
         "snippet": "sn",
         "payload": {"headers": [\(headersJSON)]}}
        """
    return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
}

/// `testMessage` overload accepting a numeric historyId directly — for call
/// sites that already have a raw history version and would otherwise need a
/// throwaway `String(...)` at every call.
func testMessage(
    id: String, threadID: String = "t1", historyID: Int, internalDate: String = "1000",
    labels: [String] = ["INBOX"], subject: String = "s"
) -> GmailMessage {
    testMessage(
        id: id, threadID: threadID, historyID: String(historyID), internalDate: internalDate,
        labels: labels, subject: subject)
}

/// Builds a full-format GmailMessage carrying a text/plain body, for
/// hydration tests. `internalDate` is milliseconds since epoch, as a string
/// (Gmail's wire format). `messageID`/`references` (M5 Task 5) optionally
/// add a `Message-ID`/`References` header — omitted entirely when `nil`, so
/// every pre-existing call site round-trips unchanged.
func testMessageWithBody(
    id: String, threadID: String = "t1", historyID: String, internalDate: String,
    labels: [String] = ["INBOX"], subject: String = "s", plainText: String,
    messageID: String? = nil, references: String? = nil
) -> GmailMessage {
    let encodedBody = Data(plainText.utf8).base64EncodedString()
    let labelIDsJSON = "[\(labels.map { "\"\($0)\"" }.joined(separator: ", "))]"
    var headersJSON = """
        {"name": "From", "value": "a@ex.com"}, {"name": "To", "value": "b@ex.com"}, \
        {"name": "Subject", "value": "\(subject)"}
        """
    if let messageID { headersJSON += ", {\"name\": \"Message-ID\", \"value\": \"\(messageID)\"}" }
    if let references { headersJSON += ", {\"name\": \"References\", \"value\": \"\(references)\"}" }
    let json = """
        {"id": "\(id)", "threadId": "\(threadID)", "historyId": "\(historyID)",
         "internalDate": "\(internalDate)", "labelIds": \(labelIDsJSON),
         "snippet": "sn",
         "payload": {"mimeType": "text/plain", "body": {"data": "\(encodedBody)"},
            "headers": [\(headersJSON)]}}
        """
    return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
}
