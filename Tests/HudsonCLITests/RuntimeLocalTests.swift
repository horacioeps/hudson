import Foundation
import GmailKit
import Store
import Testing
@testable import HudsonCLI

@Test func localRuntimeThrowsCleanlyWithNoAccount() async throws {
    // Point at a throwaway empty DB via the injectable path seam (add a
    // `local(databaseURL:)` overload for tests; the no-arg uses HudsonPaths).
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hudson-local-test-temp")
    defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: GmailError.self) {
        _ = try await LocalRuntime.local(databaseURL: dir.appendingPathComponent("db.sqlite"))
    }
}
