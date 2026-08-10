import AppKit
import CoreText
import SwiftUI

/// Bundled-font registration + font helpers. `register()` is idempotent and
/// safe to call more than once (CoreText returns an already-registered error we
/// swallow). If a face fails to register or is absent, `serif`/`ui` fall back to
/// the system serif / system font so the app still renders — fidelity degrades,
/// nothing crashes.
/// `@MainActor`-isolated because every caller is a SwiftUI `View` body (itself
/// main-actor), so the compiler can verify the `didRegister` guard is race-free
/// without an `unsafe` escape — and a future off-main caller is then forced to
/// hop, which is exactly the Swift 6 guarantee we want here.
@MainActor
public enum Typography {
    // A one-shot idempotency guard: `register()` returns early once the bundled
    // faces are in. Plain mutable static — main-actor isolation (above) makes it
    // safe, no lock needed.
    private static var didRegister = false

    /// Registers every `.ttf` bundled under `Resources/Fonts`. Enumerates the
    /// directory rather than hard-coding filenames, so a missing or renamed
    /// face never crashes registration — it just doesn't get picked up, and
    /// `serif`/`ui` fall back to a system font.
    public static func register() {
        guard !didRegister else { return }
        didRegister = true
        let fonts = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in fonts {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    public static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        register()
        return resolved(serifCandidates, size: size, weight: weight, fallback: .serif)
    }

    public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        register()
        return resolved(uiCandidates, size: size, weight: weight, fallback: nil)
    }

    // Candidate family names in preference order. The bundled VARIABLE fonts
    // register under the first name in each list; if someone later swaps in a
    // static instance that registers under a cleaner name, add it to the front.
    // We probe `NSFont(name:size:)` to pick the first that actually resolves,
    // rather than trusting one hard-coded string — `Font.custom` would silently
    // fall back to the system font on a miss, and we'd never notice the face is
    // wrong. Ground truth (confirmed from the shipped .ttf name tables):
    //   Newsreader variable  → family "Newsreader 16pt"
    //   Instrument Sans var.  → family "Instrument Sans"
    private static let serifCandidates = ["Newsreader", "Newsreader 16pt"]
    private static let uiCandidates    = ["Instrument Sans", "InstrumentSans"]

    /// First candidate that resolves to a real `NSFont`, as a weighted
    /// `Font.custom`; otherwise a system font (serif design when `fallback ==
    /// .serif`) so the app always renders.
    private static func resolved(
        _ candidates: [String], size: CGFloat, weight: Font.Weight, fallback: Font.Design?
    ) -> Font {
        if let name = candidates.first(where: { NSFont(name: $0, size: size) != nil }) {
            return .custom(name, size: size).weight(weight)
        }
        return .system(size: size, design: fallback ?? .default).weight(weight)
    }
}
