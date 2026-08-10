import Foundation
import GmailKit
@testable import SyncEngine

/// Scriptable in-memory Gmail for SyncEngine tests: serves canned list pages,
/// messages, and history pages; records every call.
actor ScriptedGmail: GmailAPI {
    var profile: Profile
    var listPages: [MessageListPage]
    var messagesByID: [String: GmailMessage]
    var historyPages: [HistoryPage]
    /// When set, listHistory throws this (e.g. 404 expiry) instead of serving.
    var historyError: GmailError?
    private(set) var calls: [String] = []

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
}

/// Builds a metadata-format GmailMessage for tests.
func testMessage(
    id: String, threadID: String = "t1", historyID: String, internalDate: String = "1000",
    labels: [String] = ["INBOX"], subject: String = "s"
) -> GmailMessage {
    // Decodable structs: round-trip through JSON to construct.
    let json = """
        {"id": "\(id)", "threadId": "\(threadID)", "historyId": "\(historyID)",
         "internalDate": "\(internalDate)", "labelIds": \(labels.map { "\"\($0)\"" }),
         "snippet": "sn",
         "payload": {"headers": [
            {"name": "From", "value": "a@ex.com"}, {"name": "To", "value": "b@ex.com"},
            {"name": "Subject", "value": "\(subject)"}]}}
        """
    return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
}

/// Builds a full-format GmailMessage carrying a text/plain body, for
/// hydration tests. `internalDate` is milliseconds since epoch, as a string
/// (Gmail's wire format).
func testMessageWithBody(
    id: String, threadID: String = "t1", historyID: String, internalDate: String,
    labels: [String] = ["INBOX"], subject: String = "s", plainText: String
) -> GmailMessage {
    let encodedBody = Data(plainText.utf8).base64EncodedString()
    let json = """
        {"id": "\(id)", "threadId": "\(threadID)", "historyId": "\(historyID)",
         "internalDate": "\(internalDate)", "labelIds": \(labels.map { "\"\($0)\"" }),
         "snippet": "sn",
         "payload": {"mimeType": "text/plain", "body": {"data": "\(encodedBody)"},
            "headers": [
            {"name": "From", "value": "a@ex.com"}, {"name": "To", "value": "b@ex.com"},
            {"name": "Subject", "value": "\(subject)"}]}}
        """
    return try! JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
}
