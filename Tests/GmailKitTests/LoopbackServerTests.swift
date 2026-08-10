import Foundation
import Testing
@testable import GmailKit

@Test func capturesCodeFromCallback() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    async let code = server.waitForCallback(expectedState: "expected-state", timeout: 10)
    // Simulate the browser redirect Google performs.
    let url = URL(string: "http://127.0.0.1:\(port)/callback?code=the-code&state=expected-state")!
    let (body, _) = try await URLSession.shared.data(from: url)

    #expect(try await code == "the-code")
    #expect(String(decoding: body, as: UTF8.self).contains("Hudson is connected"))
    await server.stop()
}

@Test func rejectsMismatchedState() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    // `#expect(throws:)` expands to a closure, and closures cannot capture
    // an `async let` binding (a Swift compiler restriction) — a `Task`
    // gives the same "run concurrently, inspect later" shape without it.
    let codeTask = Task { try await server.waitForCallback(expectedState: "expected-state", timeout: 10) }
    let url = URL(string: "http://127.0.0.1:\(port)/callback?code=x&state=WRONG")!
    _ = try await URLSession.shared.data(from: url)

    await #expect(throws: GmailError.self) { _ = try await codeTask.value }
    await server.stop()
}

@Test func surfacesUserDenial() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    let codeTask = Task { try await server.waitForCallback(expectedState: "s", timeout: 10) }
    let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=s")!
    _ = try await URLSession.shared.data(from: url)

    await #expect(throws: GmailError.auth("Google reported: access_denied")) {
        _ = try await codeTask.value
    }
    await server.stop()
}

@Test func timesOutWhenNoCallbackArrives() async throws {
    // Regression test for the deadlock defect: `waitForCallback` must
    // actually throw when the timeout elapses, not hang forever waiting
    // on a continuation that nothing will ever resume.
    let server = LoopbackServer()
    _ = try await server.start()

    await #expect(throws: GmailError.self) {
        _ = try await server.waitForCallback(expectedState: "s", timeout: 0.2)
    }
    await server.stop()
}

@Test func missingCodeSurfacesAuthError() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    let codeTask = Task { try await server.waitForCallback(expectedState: "s", timeout: 10) }
    let url = URL(string: "http://127.0.0.1:\(port)/callback?state=s")!
    _ = try await URLSession.shared.data(from: url)

    await #expect(throws: GmailError.auth("Callback carried no authorization code.")) {
        _ = try await codeTask.value
    }
    await server.stop()
}

@Test func stopMidWaitResumesWaiterWithError() async throws {
    // `stop()` must never leak a pending continuation: whoever is inside
    // `waitForCallback` has to be resumed (with an error), not left
    // suspended forever. This holds regardless of whether `stop()` wins
    // the race against `waitForCallback` registering its wait, because
    // the server buffers whichever side arrives first.
    let server = LoopbackServer()
    _ = try await server.start()

    let codeTask = Task { try await server.waitForCallback(expectedState: "s", timeout: 10) }
    await server.stop()

    await #expect(throws: GmailError.self) {
        _ = try await codeTask.value
    }
}

@Test func startThrowsWhenCalledTwice() async throws {
    let server = LoopbackServer()
    _ = try await server.start()

    await #expect(throws: GmailError.self) {
        _ = try await server.start()
    }
    await server.stop()
}

@Test func waitForCallbackThrowsWhenCalledAgainAfterFinishing() async throws {
    let server = LoopbackServer()
    _ = try await server.start()

    // Sequential, not concurrent, so this is deterministic: let the first
    // wait finish (via timeout) before attempting the second call.
    _ = try? await server.waitForCallback(expectedState: "s", timeout: 0.1)

    await #expect(throws: GmailError.self) {
        _ = try await server.waitForCallback(expectedState: "s", timeout: 10)
    }
    await server.stop()
}
