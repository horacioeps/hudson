import Foundation
@testable import GmailKit

/// Test transport: returns canned (body, status) pairs in order and records
/// every request so tests can assert on URLs, headers, and bodies.
actor MockTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    private var requests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw GmailError.network("MockTransport ran out of stubbed responses.")
        }
        let (data, status) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}
