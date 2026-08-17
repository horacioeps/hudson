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

    /// Registers every bundled `.ttf`. Enumerates the bundle rather than
    /// hard-coding filenames, so a missing or renamed face never crashes
    /// registration — it just doesn't get picked up, and `serif`/`ui` fall back
    /// to a system font.
    public static func register() {
        guard !didRegister else { return }
        didRegister = true
        for url in bundledFontURLs() {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// The name SwiftPM gives HudsonUI's resource bundle. Derived from
    /// `<package>_<target>`, so it changes only if the package or target is
    /// renamed — at which point `bundledFontURLs()` returns empty and the app
    /// renders in system faces rather than failing to launch.
    /// `nonisolated` for the same reason as the lookups below: it is an
    /// immutable constant, so actor isolation buys nothing and only forces
    /// callers to hop.
    nonisolated static let resourceBundleName = "Hudson_HudsonUI.bundle"

    /// Every bundled `.ttf`, located WITHOUT ever touching `Bundle.module`.
    ///
    /// Touching it at all was the bug. SwiftPM's generated `Bundle.module`
    /// probes exactly two paths and calls `fatalError` when both miss: the app
    /// bundle ROOT (`Bundle.main.bundleURL`, NOT its `Resources` directory),
    /// and an absolute path into the `.build` directory of the machine that
    /// compiled the binary. Neither survives packaging. `codesign` requires a
    /// nested resource bundle to sit in `Contents/Resources`, which is not the
    /// root, and a user's Mac has no `.build` directory — so `Bundle.module`
    /// resolved on the maintainer's machine via the build path and hard-crashed
    /// everywhere else, inside the first `Typography.serif` call that renders
    /// `RootView.loadingPlaceholder`. The app died before drawing one frame.
    ///
    /// An empty return is a legitimate outcome, not a failure to report:
    /// `resolved(_:size:weight:fallback:)` falls back to system faces, so a
    /// missing font costs fidelity. It must never cost a launch.
    /// `nonisolated` because it reads only the filesystem and its arguments —
    /// the main-actor isolation on this enum exists for `didRegister`, and
    /// borrowing it here would force every caller and test onto the main actor
    /// for a pure lookup.
    nonisolated static func bundledFontURLs(searchPaths: [URL] = resourceSearchPaths()) -> [URL] {
        for directory in searchPaths {
            guard let bundle = Bundle(url: directory.appending(path: resourceBundleName))
            else { continue }
            // SwiftPM FLATTENS `Resources/Fonts/*.ttf` into the bundle root, so
            // the original `subdirectory: "Fonts"` matched nothing and the faces
            // never registered even on the machine where the lookup succeeded —
            // the app has been rendering in system fonts throughout. Both
            // layouts are probed so that neither a change in SwiftPM's
            // flattening nor a deliberate move back into a folder silently
            // drops the fonts again.
            let found = (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
                + (bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? [])
            if !found.isEmpty { return found }
        }
        return []
    }

    /// Where the nested resource bundle can legitimately sit, in the order the
    /// three shipping shapes actually occur:
    ///   - a packaged `.app`     → `Contents/Resources`
    ///   - `swift run HudsonApp` → beside the executable in `.build/<config>`
    ///   - the test runner       → also `.build/<config>`, next to the `.xctest`
    ///
    /// Probing all three is what makes the packaged app and the dev loop agree.
    /// The old code only ever worked in the dev loop, which is precisely why the
    /// break reached a user before it reached a test.
    nonisolated static func resourceSearchPaths() -> [URL] {
        var paths: [URL] = []
        if let resources = Bundle.main.resourceURL { paths.append(resources) }
        paths.append(Bundle.main.bundleURL)
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            paths.append(executableDirectory)
        }
        return paths
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
