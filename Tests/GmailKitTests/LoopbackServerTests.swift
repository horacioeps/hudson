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
    #expect(String(decoding: body, as: UTF8.self).contains("Hudson"))
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
