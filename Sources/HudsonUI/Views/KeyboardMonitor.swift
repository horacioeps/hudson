import AppKit
import SwiftUI

/// Mounts a single, app-wide `NSEvent` local key-down monitor and routes
/// every key press through `KeyRouter` before SwiftUI's own responder chain
/// ever sees it. An `NSViewRepresentable` because there is no supported
/// SwiftUI-only way to install a monitor with lifecycle tied to a view's
/// presence — `.onKeyPress` was tried first and dropped: it relies on the
/// key event bubbling up from whichever control currently has focus (a
/// query `TextField`, most of the time), which a prior review flagged as
/// fragile for a GLOBAL keymap that has to work identically whether or not
/// any particular view happens to be in the focused responder chain. The
/// monitor, mounted invisibly behind `RootView`'s assembled panes, is the
/// single source of truth instead; see `KeyboardMap.swift`'s `KeyRouter`
/// for the actual routing policy, which this file contains none of.
struct KeyboardMonitor: NSViewRepresentable {
    let appModel: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(appModel: appModel)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // `appModel` never changes identity for a running `RootView` (one
        // `AppModel` per launch) — `install` itself is a no-op past the
        // first call (see its `guard`), so re-running this on every SwiftUI
        // update is harmless, not a re-install.
        context.coordinator.install(appModel: appModel)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Owns the monitor token. A separate object (not the `NSView` itself)
    /// because `dismantleNSView` is `static` — it has no `self` to read
    /// instance state from, only whatever AppKit hands back via
    /// `makeCoordinator()`.
    @MainActor
    final class Coordinator {
        private var monitor: Any?

        func install(appModel: AppModel) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak appModel] event in
                guard let appModel else { return event }
                guard
                    let action = KeyRouter.route(
                        KeyDescriptor(event: event), context: appModel.keyboardContext)
                else {
                    return event  // not ours — let AppKit/SwiftUI have it (e.g. a query field's typing)
                }
                appModel.apply(action)
                return nil  // consumed
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// `isolated` (SE-0371) — `monitor` is `@MainActor`-isolated
        /// storage, so a plain `nonisolated deinit` can't touch it without
        /// an unsafe escape hatch. Matches the model layer's own
        /// `InboxModel`/`ThreadModel`/`AppModel` convention.
        isolated deinit {
            remove()
        }
    }
}

extension KeyDescriptor {
    /// The only AppKit-aware corner of the keyboard map — translates a real
    /// `NSEvent` into the AppKit-free `KeyDescriptor` that `KeyRouter.route`
    /// actually reasons about. `charactersIgnoringModifiers` (not
    /// `characters`) so a ⌘-held combo still carries its base letter (⌘K ->
    /// `"k"`), and so Shift alone doesn't turn `/` into `?` under the hood —
    /// `KeyRouter` lowercases anyway, matching Shift-held letters too.
    init(event: NSEvent) {
        self.init(
            characters: event.charactersIgnoringModifiers,
            special: SpecialKey(keyCode: event.keyCode),
            command: event.modifierFlags.contains(.command))
    }
}

extension KeyDescriptor.SpecialKey {
    /// macOS virtual keycodes for the fixed set of non-character keys this
    /// app's keymap cares about. There's no public AppKit enum for these —
    /// only the documented-stable raw `keyCode` values (Carbon's
    /// `HIToolbox/Events.h`, still what AppKit itself uses under the hood).
    init?(keyCode: UInt16) {
        switch keyCode {
        case 126: self = .upArrow
        case 125: self = .downArrow
        case 36, 76: self = .return  // Return, and the numeric-keypad Enter
        case 53: self = .escape
        default: return nil
        }
    }
}
