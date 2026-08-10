import Foundation
@testable import GmailKit

/// Test transport: returns canned (body, status) pairs in order and records
/// every request so tests can assert on URLs, headers, and bodies.
///
/// `headers` optionally supplies response headers (e.g. `Retry-After`) keyed
/// by the zero-based index of the response they belong to, for tests that
/// need to assert on header-driven behavior.
actor MockTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    private let headers: [Int: [String: String]]
    private var nextResponseIndex = 0
    private var requests: [URLRequest] = []

    init(responses: [(Data, Int)], headers: [Int: [String: String]] = [:]) {
        self.responses = responses
        self.headers = headers
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw GmailError.network("MockTransport ran out of stubbed responses.")
        }
        let (data, status) = responses.removeFirst()
        let index = nextResponseIndex
        nextResponseIndex += 1
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers[index]
        )!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}
