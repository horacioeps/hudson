import Testing
@testable import HudsonUI

// MARK: - Palette context

@Test func paletteArrowsMoveHighlight() {
    #expect(
        KeyRouter.route(KeyDescriptor(special: .downArrow), context: .palette) == .moveHighlight(1))
    #expect(
        KeyRouter.route(KeyDescriptor(special: .upArrow), context: .palette) == .moveHighlight(-1))
}

@Test func paletteReturnPerformsHighlighted() {
    #expect(
        KeyRouter.route(KeyDescriptor(special: .return), context: .palette) == .performHighlighted)
}

@Test func paletteEscapeCloses() {
    #expect(KeyRouter.route(KeyDescriptor(special: .escape), context: .palette) == .closePalette)
}

/// Ordinary typing (no special key) must pass through — `nil` — so the
/// palette's query `TextField` keeps receiving characters.
@Test func paletteTypingPassesThrough() {
    #expect(KeyRouter.route(KeyDescriptor(characters: "a"), context: .palette) == nil)
}

/// A plain "k" (no ⌘) while the palette is open must NOT be treated as the
/// list's "select previous" shortcut — context isolation, not leakage.
@Test func paletteDoesNotLeakListShortcuts() {
    #expect(KeyRouter.route(KeyDescriptor(characters: "k"), context: .palette) == nil)
}

// MARK: - Search context

@Test func searchEscapeCloses() {
    #expect(KeyRouter.route(KeyDescriptor(special: .escape), context: .search) == .closeSearch)
}

/// Every other key — including arrows/Return, unlike the palette — passes
/// through untouched; search has no keyboard-navigable result list.
@Test func searchOnlyEscapeIsHandled() {
    #expect(KeyRouter.route(KeyDescriptor(characters: "a"), context: .search) == nil)
    #expect(KeyRouter.route(KeyDescriptor(special: .downArrow), context: .search) == nil)
    #expect(KeyRouter.route(KeyDescriptor(special: .return), context: .search) == nil)
}

// MARK: - List context

@Test func listSingleLetterShortcutsRoute() {
    #expect(KeyRouter.route(KeyDescriptor(characters: "j"), context: .list) == .selectNext)
    #expect(KeyRouter.route(KeyDescriptor(characters: "k"), context: .list) == .selectPrevious)
    #expect(KeyRouter.route(KeyDescriptor(characters: "e"), context: .list) == .archiveSelected)
    #expect(KeyRouter.route(KeyDescriptor(characters: "s"), context: .list) == .toggleStarSelected)
    #expect(KeyRouter.route(KeyDescriptor(characters: "u"), context: .list) == .toggleReadSelected)
    #expect(KeyRouter.route(KeyDescriptor(characters: "o"), context: .list) == .openSelected)
    #expect(KeyRouter.route(KeyDescriptor(characters: "/"), context: .list) == .toggleSearch)
}

@Test func listReturnOpensSelected() {
    #expect(KeyRouter.route(KeyDescriptor(special: .return), context: .list) == .openSelected)
}

@Test func listEscapeClearsSelection() {
    #expect(KeyRouter.route(KeyDescriptor(special: .escape), context: .list) == .clearSelection)
}

@Test func listCommandKTogglesPalette() {
    #expect(
        KeyRouter.route(KeyDescriptor(characters: "k", command: true), context: .list) == .togglePalette)
}

@Test func listCommandFTogglesSearch() {
    #expect(
        KeyRouter.route(KeyDescriptor(characters: "f", command: true), context: .list) == .toggleSearch)
}

/// ⌘N opens the compose sheet — Task 4's wiring. Scoped to the list context
/// only, same as ⌘K/⌘F above (see `routeInList`'s doc comment on why the
/// palette/search overlays don't re-route their own ⌘-combos).
@Test func listCommandNOpensComposer() {
    #expect(
        KeyRouter.route(KeyDescriptor(characters: "n", command: true), context: .list) == .composeNew)
}

/// Shortcuts are case-insensitive — `charactersIgnoringModifiers` still
/// applies Shift, so a Shift-held "J" must route the same as plain "j".
@Test func listShortcutsAreCaseInsensitive() {
    #expect(KeyRouter.route(KeyDescriptor(characters: "J"), context: .list) == .selectNext)
}

/// An unmapped letter, and a ⌘-combo with no assigned action, both pass
/// through rather than being silently swallowed.
@Test func listUnmappedKeysPassThrough() {
    #expect(KeyRouter.route(KeyDescriptor(characters: "z"), context: .list) == nil)
    #expect(KeyRouter.route(KeyDescriptor(characters: "z", command: true), context: .list) == nil)
}

@Test func listArrowsAreUnhandled() {
    #expect(KeyRouter.route(KeyDescriptor(special: .upArrow), context: .list) == nil)
    #expect(KeyRouter.route(KeyDescriptor(special: .downArrow), context: .list) == nil)
}
