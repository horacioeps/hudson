import Testing
@testable import HudsonUI

/// With a thread selected, the triage commands (archive/star/mark-read) are
/// all present — they act on the selection, so they only make sense then.
@MainActor
@Test func reloadWithSelectionIncludesTriageCommands() {
    let model = CommandModel()
    model.reload(splits: [], hasSelection: true)

    let kinds = model.results.map(\.kind)
    #expect(kinds.contains(.archive))
    #expect(kinds.contains(.toggleStar))
    #expect(kinds.contains(.toggleRead))
}

/// Without a selection, those same triage commands are absent entirely
/// (v1: filtered out, not shown-but-disabled) — nothing for them to act on.
@MainActor
@Test func reloadWithoutSelectionExcludesTriageCommands() {
    let model = CommandModel()
    model.reload(splits: [], hasSelection: false)

    let kinds = model.results.map(\.kind)
    #expect(!kinds.contains(.archive))
    #expect(!kinds.contains(.toggleStar))
    #expect(!kinds.contains(.toggleRead))
}

/// `openSearch` and one `switchSplit` per tab are always present,
/// regardless of selection state.
@MainActor
@Test func reloadAlwaysIncludesSearchAndOneSwitchSplitPerTab() {
    let model = CommandModel()
    let splits = [
        SplitTab(key: "important", title: "Important", count: 4),
        SplitTab(key: "primary", title: "Primary", count: 10),
    ]
    model.reload(splits: splits, hasSelection: false)

    let kinds = model.results.map(\.kind)
    #expect(kinds.contains(.openSearch))
    #expect(kinds.contains(.switchSplit("important")))
    #expect(kinds.contains(.switchSplit("primary")))
}

/// Snooze is listed (so users can discover it), but only as a "Coming
/// soon" placeholder — no working behavior lands until M6.
@MainActor
@Test func reloadIncludesSnoozeAsComingSoonPlaceholder() {
    let model = CommandModel()
    model.reload(splits: [], hasSelection: true)

    let snooze = model.results.first { $0.kind == .snooze }
    #expect(snooze?.subtitle == "Coming soon")
}

/// Typing "imp" against a split titled "Important" surfaces its
/// "Switch to Important" command — the palette's primary use case.
@MainActor
@Test func typingImpSurfacesSwitchToImportantSplitCommand() {
    let model = CommandModel()
    let splits = [SplitTab(key: "important", title: "Important", count: 4)]
    model.reload(splits: splits, hasSelection: false)

    model.query = "imp"
    model.filter()

    #expect(model.results.contains { $0.title == "Switch to Important" })
}

/// `filter()` drops non-matching commands and ranks the best match first —
/// "arch" matches both "Archive" (a prefix match) and "Search" (scattered),
/// so Archive must lead, and non-matching commands like Star must vanish.
@MainActor
@Test func filterDropsNonMatchesAndRanksBestScoreFirst() throws {
    let model = CommandModel()
    model.reload(splits: [], hasSelection: true)

    model.query = "arch"
    model.filter()

    let first = try #require(model.results.first)
    #expect(first.kind == .archive)
    #expect(!model.results.contains { $0.kind == .toggleStar })
}

/// An empty query restores the full, unranked base list built by
/// `reload()` — same order, nothing filtered out.
@MainActor
@Test func emptyQueryRestoresFullBaseOrder() {
    let model = CommandModel()
    model.reload(splits: [], hasSelection: true)
    let baseOrder = model.results.map(\.id)

    model.query = "zzz-does-not-match-anything"
    model.filter()
    #expect(model.results.isEmpty)

    model.query = ""
    model.filter()
    #expect(model.results.map(\.id) == baseOrder)
}
