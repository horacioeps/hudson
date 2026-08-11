import Foundation
import Testing

@testable import AIKit

/// Minimal coverage for the `ScriptedLLMHTTP` double itself — Task 3/4 rely
/// on it to stand in for `LLMHTTP` without a real socket, so its two
/// contracts (replay the script verbatim; record every request) need to be
/// proven once here rather than trusted by inspection.
@Test func scriptedLLMHTTPReplaysScriptAndRecordsTheRequest() async throws {
    let script = [Data("{\"delta\":1}".utf8), Data("{\"delta\":2}".utf8)]
    let http = ScriptedLLMHTTP(script: script)
    let request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)

    let stream = try await http.stream(request)
    var received: [Data] = []
    for try await chunk in stream {
        received.append(chunk)
    }

    #expect(received == script)
    #expect(http.callCount == 1)
    #expect(http.lastRequest?.url == request.url)
}
