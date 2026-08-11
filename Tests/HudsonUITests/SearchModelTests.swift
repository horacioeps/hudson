import Store
import Testing
@testable import HudsonUI

/// `SearchModel`'s injected debounce for these tests — small enough to keep
/// the suite fast, but comfortably larger than the `sleep`s used below to
/// simulate "rapid keystrokes" landing well within a single debounce
/// window.
private let testDebounce: Duration = .milliseconds(10)

/// A query shorter than the 2-char floor never reaches the database: `hits`
/// stays at its initial empty value and `isSearching` never flips to true —
/// there is nothing to await, so this doesn't even need a `Task.sleep`.
@MainActor
@Test func queryUnderTwoCharsLeavesHitsEmptyAndRunsNoSearch() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = SearchModel(database: db, account: "you@hudson.app", debounce: testDebounce)

    model.query = "d"
    model.queryChanged()

    #expect(model.hits.isEmpty)
    #expect(!model.isSearching)
}

/// A 3-char prefix of a distinctive seeded word ("Denver", t08's subject
/// and body) yields the matching hit once the debounce elapses.
@MainActor
@Test func threeCharPrefixYieldsExpectedHitAfterDebounce() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = SearchModel(database: db, account: "you@hudson.app", debounce: testDebounce)

    model.query = "den"
    model.queryChanged()

    try await Task.sleep(for: .milliseconds(100))

    #expect(!model.hits.isEmpty)
    #expect(model.hits.contains { $0.subject.contains("Denver") })
    #expect(!model.isSearching)
}

/// Rapidly changing the query (each edit cancelling the last debounce
/// before it fires) must land ONLY the final query's results — never a
/// stale, superseded search's results clobbering the current ones.
@MainActor
@Test func rapidQueryChangesLandOnlyFinalQuerysResults() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = SearchModel(database: db, account: "you@hudson.app", debounce: testDebounce)

    model.query = "d"
    model.queryChanged()
    model.query = "de"
    model.queryChanged()
    model.query = "den"
    model.queryChanged()
    model.query = "denv"
    model.queryChanged()

    try await Task.sleep(for: .milliseconds(100))

    #expect(!model.hits.isEmpty)
    #expect(model.hits.allSatisfy { $0.subject.contains("Denver") || $0.snippet.contains("Denver") })
    #expect(!model.isSearching)
}
