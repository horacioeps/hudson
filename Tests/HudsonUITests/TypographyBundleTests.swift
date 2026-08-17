import Foundation
import Testing

@testable import HudsonUI

// MARK: - The regression tests for the 0.1.1 launch crash
//
// Hudson 0.1.0 and 0.1.1 died on launch on every Mac except the maintainer's,
// inside `Bundle.module`:
//
//   0  libswiftCore  _assertionFailure(_:_:file:line:flags:)
//   1  HudsonApp     closure #1 in variable initialization expression of
//                    static NSBundle.module
//   5  HudsonApp     specialized static Typography.register()
//   6  HudsonApp     specialized static Typography.serif(_:_:)
//   7  HudsonApp     closure #1 in RootView.loadingPlaceholder.getter
//
// SwiftPM's generated accessor probes the app bundle ROOT and an absolute
// `.build` path from the compiling machine, then calls `fatalError`. A packaged
// .app matches neither: codesign puts the nested bundle in Contents/Resources,
// and a user's Mac has no .build directory.
//
// These tests drive `bundledFontURLs(searchPaths:)` against the real on-disk
// layouts rather than the ambient one, because the ambient layout is exactly
// what hid the bug — the dev loop resolved, so nothing ever exercised the
// shape a user receives.

/// Builds a throwaway resource bundle holding one file named like a font.
///
/// The content is not a real typeface: every assertion here is about whether
/// the URL is *found*, and CoreText never sees these. Keeping it fake also
/// keeps the tests independent of which faces the app happens to ship.
private func makeResourceBundle(
    at directory: URL, fontSubdirectory: String? = nil
) throws -> URL {
    let bundle = directory.appending(path: Typography.resourceBundleName)
    let fontDirectory = fontSubdirectory.map { bundle.appending(path: $0) } ?? bundle
    try FileManager.default.createDirectory(at: fontDirectory, withIntermediateDirectories: true)
    try Data("not a real typeface".utf8)
        .write(to: fontDirectory.appending(path: "Newsreader.ttf"))
    return bundle
}

private func makeScratchDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "TypographyBundleTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - The shape a user actually receives

/// **The regression test for the reported crash.**
///
/// Reproduces a packaged `.app`: `Hudson.app/Contents/Resources/` holds the
/// nested resource bundle, and `Hudson.app/` itself does not. That is the one
/// arrangement `Bundle.module` cannot resolve, and the one every download has.
@Test func findsFontsInAPackagedAppResourcesDirectory() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let appBundle = scratch.appending(path: "Hudson.app")
    let resources = appBundle.appending(path: "Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    _ = try makeResourceBundle(at: resources)

    let found = Typography.bundledFontURLs(searchPaths: [resources, appBundle])
    #expect(found.count == 1)
    #expect(found.first?.lastPathComponent == "Newsreader.ttf")
}

/// The bundle root is searched too, which is the `swift run HudsonApp` layout:
/// SwiftPM drops `Hudson_HudsonUI.bundle` beside the executable rather than
/// inside a `Resources` directory. Both shapes have to work from one code path,
/// or the dev loop and the shipped app disagree again.
@Test func findsFontsBesideTheExecutable() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    _ = try makeResourceBundle(at: scratch)

    #expect(Typography.bundledFontURLs(searchPaths: [scratch]).count == 1)
}

// MARK: - The second bug: the fonts never registered at all

/// SwiftPM flattens `Resources/Fonts/*.ttf` to the bundle root, so the original
/// `subdirectory: "Fonts"` matched nothing and no bundled face was ever
/// registered — including on the maintainer's Mac, where the app quietly
/// rendered in system fonts instead of Newsreader.
@Test func findsFontsFlattenedIntoTheBundleRoot() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    _ = try makeResourceBundle(at: scratch, fontSubdirectory: nil)

    let found = Typography.bundledFontURLs(searchPaths: [scratch])
    #expect(found.count == 1, "a flattened bundle is the layout SwiftPM actually produces")
}

/// The nested layout is probed as well, so a future SwiftPM that stops
/// flattening — or a deliberate move back into a folder — does not silently
/// strip the typography again.
@Test func findsFontsInsideANestedFontsDirectory() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    _ = try makeResourceBundle(at: scratch, fontSubdirectory: "Fonts")

    #expect(Typography.bundledFontURLs(searchPaths: [scratch]).count == 1)
}

// MARK: - Absence must cost fidelity, never a launch

/// The crash was not "the fonts are missing", it was "the app decided a missing
/// bundle is fatal". A resolver that finds nothing has to return empty and let
/// `resolved(_:size:weight:fallback:)` fall back to system faces.
@Test func returnsEmptyRatherThanCrashingWhenNoBundleExists() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    #expect(Typography.bundledFontURLs(searchPaths: [scratch]).isEmpty)
}

/// An empty search path list is the degenerate version of the same guarantee.
@Test func returnsEmptyForNoSearchPathsAtAll() {
    #expect(Typography.bundledFontURLs(searchPaths: []).isEmpty)
}

/// A bundle directory that exists but holds no `.ttf` must also be survivable —
/// `Bundle(url:)` succeeds on any directory, so this is a reachable state
/// whenever a build drops the fonts.
@Test func returnsEmptyForABundleContainingNoFonts() throws {
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    try FileManager.default.createDirectory(
        at: scratch.appending(path: Typography.resourceBundleName),
        withIntermediateDirectories: true)

    #expect(Typography.bundledFontURLs(searchPaths: [scratch]).isEmpty)
}

// MARK: - Registration itself

/// `register()` is the frame that crashed. Calling it must be safe regardless
/// of what the ambient layout holds, and must stay idempotent.
@Test @MainActor func registerIsSafeAndIdempotent() {
    Typography.register()
    Typography.register()
    // Reaching here at all is the assertion: the old implementation trapped
    // inside Bundle.module on any machine without the compiling .build path.
    #expect(Bool(true))
}

/// The real ambient lookup must never trap in the environment the suite runs
/// in, which is the third shipping shape (`.build/<config>` beside the
/// `.xctest`).
@Test func ambientSearchPathsResolveWithoutTrapping() {
    #expect(!Typography.resourceSearchPaths().isEmpty)
    _ = Typography.bundledFontURLs()
}
