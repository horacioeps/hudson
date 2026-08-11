import Foundation

/// Which overlay (if any) currently owns keyboard priority — determines how
/// `KeyRouter.route` interprets a keystroke. Exactly one of the app's three
/// keyboard "modes": the ⌘K palette, the search overlay, or (when neither is
/// showing) the inbox list itself.
public enum KeyboardContext: Sendable, Equatable {
    case palette
    case search
    /// The compose/reply sheet is open and owns the keyboard: EVERY key is
    /// typed into the body (only Esc is special), so the list's single-letter
    /// triage shortcuts (j/k/e/s/u/o) must NOT fire — otherwise you can't type
    /// those letters in an email.
    case composer
    case list
}

/// A key event reduced to exactly what `KeyRouter` needs to route it —
/// deliberately independent of AppKit (no `NSEvent` anywhere in this file),
/// so the routing rules below are unit-testable without a live event loop
/// or window server. `KeyboardMonitor` (the AppKit adapter, `Views/
/// KeyboardMonitor.swift`) is the only place that builds one of these from
/// a real `NSEvent`.
public struct KeyDescriptor: Sendable, Equatable {
    /// A non-character key AppKit reports via `keyCode` rather than
    /// `characters` — the small, fixed set this app's keymap cares about.
    public enum SpecialKey: Sendable, Equatable {
        case upArrow, downArrow, `return`, escape
    }

    /// The typed character(s), ignoring modifiers (so a ⌘-held combo still
    /// carries its base letter, e.g. `"k"` for ⌘K) — `nil` for a pure
    /// modifier-only press or an unmapped special key.
    public var characters: String?
    /// Non-`nil` exactly when this key press is one of `SpecialKey`'s cases.
    public var special: SpecialKey?
    public var command: Bool

    public init(characters: String? = nil, special: SpecialKey? = nil, command: Bool = false) {
        self.characters = characters
        self.special = special
        self.command = command
    }
}

/// What a routed key event should do — the vocabulary `AppModel.apply(_:)`
/// interprets. `KeyRouter.route` returns one of these, or `nil` for "not
/// ours, let AppKit/SwiftUI have it" (typing into a focused query field, an
/// unmapped key, …).
public enum KeyAction: Sendable, Equatable {
    case moveHighlight(Int)
    case performHighlighted
    case closePalette
    case closeSearch
    case selectNext
    case selectPrevious
    case openSelected
    case archiveSelected
    case toggleStarSelected
    case toggleReadSelected
    case clearSelection
    case togglePalette
    case toggleSearch
    case composeNew
    case closeComposer
}

/// Hudson's global keymap, as a single pure function: `(context, key) ->
/// action?`. Deliberately free of AppKit/SwiftUI/`AppModel` — see
/// `KeyDescriptor`'s doc comment — so every routing rule below is directly
/// unit-testable (`KeyboardMapTests`) without a live `NSEvent` monitor.
/// `KeyboardMonitor` is the thin AppKit adapter that calls this and applies
/// the result to `AppModel`; it makes no routing decisions of its own,
/// which is what keeps the actual policy (what key does what, in which
/// mode) testable and — per the plan's Pencil `NAx8S` keyboard-overlay
/// screen — renderable from one place later.
///
/// A `nil` result means "pass the event through unmodified": the monitor
/// returns the original `NSEvent` in that case, so SwiftUI's normal
/// responder chain (a focused `TextField`, most of the time) still
/// receives it. A non-`nil` `KeyAction` means the monitor must CONSUME the
/// event (return `nil` to AppKit) after applying it — never both.
public enum KeyRouter {
    public static func route(_ event: KeyDescriptor, context: KeyboardContext) -> KeyAction? {
        switch context {
        case .palette: return routeInPalette(event)
        case .search: return routeInSearch(event)
        case .composer: return routeInComposer(event)
        case .list: return routeInList(event)
        }
    }

    /// The compose/reply sheet owns the keyboard entirely: only Esc is routed
    /// (to close the sheet); EVERYTHING else — every letter, including j/k/e/s/
    /// u/o — passes straight through to the body field. Without this, the
    /// list's single-letter triage shortcuts would eat those letters and you
    /// couldn't type them in an email.
    private static func routeInComposer(_ event: KeyDescriptor) -> KeyAction? {
        event.special == .escape ? .closeComposer : nil
    }

    /// Arrow/Return/Esc drive the palette's highlight and dismissal; every
    /// other key (ordinary typing) passes through untouched so the query
    /// field keeps working — CONSUME only what we explicitly route.
    private static func routeInPalette(_ event: KeyDescriptor) -> KeyAction? {
        guard let special = event.special else { return nil }
        switch special {
        case .upArrow: return .moveHighlight(-1)
        case .downArrow: return .moveHighlight(1)
        case .return: return .performHighlighted
        case .escape: return .closePalette
        }
    }

    /// Only Esc is special-cased here — every other key (including arrows/
    /// Return, unlike the palette) is left to the search field itself,
    /// which has no keyboard-navigable result list to drive.
    private static func routeInSearch(_ event: KeyDescriptor) -> KeyAction? {
        event.special == .escape ? .closeSearch : nil
    }

    /// The default context: single-letter triage/navigation shortcuts, plus
    /// the two combos that open an overlay. Deliberately does NOT treat
    /// ⌘K/⌘F as a context-INDEPENDENT global: once the palette or search is
    /// open, that mode owns every key itself (Esc to close, everything
    /// else to its own text field — see `routeInPalette`/`routeInSearch`),
    /// so re-toggling via the same combo while one is already showing is
    /// deliberately left unhandled here rather than routed twice.
    private static func routeInList(_ event: KeyDescriptor) -> KeyAction? {
        if let special = event.special {
            switch special {
            case .escape: return .clearSelection
            case .return: return .openSelected
            case .upArrow, .downArrow: return nil
            }
        }
        guard let characters = event.characters?.lowercased(), characters.count == 1 else { return nil }
        if event.command {
            switch characters {
            case "k": return .togglePalette
            case "f": return .toggleSearch
            case "n": return .composeNew
            default: return nil
            }
        }
        switch characters {
        case "j": return .selectNext
        case "k": return .selectPrevious
        case "e": return .archiveSelected
        case "s": return .toggleStarSelected
        case "u": return .toggleReadSelected
        case "o": return .openSelected
        case "/": return .toggleSearch
        default: return nil
        }
    }
}
