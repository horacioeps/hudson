# Hudson U1 — SwiftUI App Shell v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the visible Hudson — a warm-dark, keyboard-first, three-pane SwiftUI Mac app (sidebar · split-tab inbox list · serif reading pane, plus a ⌘K command palette and full-text search) that renders real local mail from the M1–M4 store with instant optimistic triage.

**Architecture:** A thin SwiftUI shell over the existing public `Store`/`SyncEngine` APIs. Reactive reads flow through GRDB `ValueObservation` twins of the existing one-shot reads (added to `Store`), delivered to `@MainActor @Observable` view models. Triage actions call the existing overlay-aware `enqueueMutation` (which already maintains `thread_rollup` in the same transaction), so an archive/star/read drops or updates its thread on the very next observation emit — the <16ms optimistic path, no new convergence logic. The app is a SwiftPM `@main App` executable that sets its own `NSApplication` activation policy so a `swift run`-launched binary shows a real, focusable window (a notarized `.app` bundle is a later distribution concern). The design is implemented faithfully from the Pencil file `~/Documents/hudson.pen` — tokens and per-pane specs are embedded verbatim in this plan because implementers cannot open the encrypted `.pen` file.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI (macOS 15+), GRDB.swift 7 (`ValueObservation`), Swift Testing (`import Testing`). No new external dependencies — the two-dependency limit (swift-argument-parser, GRDB) is unchanged; SwiftUI and AppKit are OS frameworks. Bundled OFL fonts (Newsreader, Instrument Sans) ship as target resources.

## Global Constraints

- **Swift 6 strict concurrency.** All view models are `@MainActor`. All Store access is via the existing `async` APIs / new `async` observation streams — never synchronous `writer.read`/`write` from the main actor. `ThreadRow`/`MessageRow`/`SearchHit`/`PendingMutation` are already `Sendable`; keep every new value type `Sendable`.
- **Two external dependencies only:** `swift-argument-parser`, `GRDB.swift`. SwiftUI/AppKit/CoreText are OS frameworks and are allowed. Do NOT add ViewInspector, SnapshotTesting, or any other package.
- **Privacy #1 (locked product decision):** the UI performs ZERO network egress on its own except the explicit, user-initiated "Sync now" action (which reuses the existing `SyncEngine`/`MutationFlusher`). No AI network calls in this milestone at all — the AI summary surface is a non-functional placeholder (M7 wires it). No telemetry, no analytics. Screenshots and demo data must use synthetic mail only, never the user's real inbox.
- **Reads are reactive; search is not.** Inbox list, thread view, sidebar counts, and pending/offline state observe via `ValueObservation`. Search uses a debounced, cancellable one-shot `searchMessages` (per the architecture doc: search is `writer.read`, NOT `ValueObservation`).
- **Triage goes through `enqueueMutation` only.** Never write canonical `message_labels` from the UI. `enqueueMutation(messageID:labelID:op:account:now:)` is the single triage entry point; it already recomputes `thread_rollup` flags in-transaction, so the optimistic drop/update is automatic. `now` is `Int64(Date().timeIntervalSince1970 * 1000)` (ms, matching `internal_date`).
- **Readability bar (open-source):** this code will be read by strangers on GitHub. Match the existing house style — doc comments explain WHY, names are full words, files are focused and single-responsibility. See `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` and the existing `Sources/Store` files for the bar.
- **Design tokens are exact.** Colors, fonts, radii, and per-pane layouts are specified verbatim below. Do not invent colors or spacing; when a value is unspecified, derive it from the nearest token and note the choice in a comment.
- **TDD, frequent commits.** Every task: failing test → run it fails → minimal implementation → run it passes → commit. View-model logic is unit-tested with Swift Testing over in-memory seeded databases; view rendering fidelity is verified by the controller via live run + screenshot against the Pencil design (Task 11).

### Design tokens (from `~/Documents/hudson.pen` → Design System frame `CNIZn` / `get_variables`)

Colors (sRGB hex):

| Token | Hex | Role |
|---|---|---|
| `bgApp` | `#1C1C1A` | window / app background |
| `bgSurface` | `#242422` | raised surfaces (rows region, reading pane) |
| `bgSunken` | `#171716` | sunken wells (palette, search field, sidebar base) |
| `bgHover` | `#2B2B28` | hover state |
| `bgSelected` | `#2C3530` | selected row (green-tinted) |
| `border` | `#32322E` | hairline dividers |
| `borderStrong` | `#474640` | stronger separators / focus ring base |
| `accent` | `#8FB5A5` | brand green — unread dots, active tab, primary buttons |
| `accentInk` | `#16211D` | text/icon on an accent fill |
| `accentSoft` | `#2A362F` | soft accent fill (subtle chips, selected sidebar item) |
| `ink` | `#ECEAE4` | primary text |
| `inkSecondary` | `#A29E95` | secondary text (snippet, addresses) |
| `inkTertiary` | `#6E6B64` | tertiary text (timestamps, meta) |
| `aiBg` | `#2E2A20` | AI surface background (amber-tinted) |
| `aiInk` | `#C7AC72` | AI accent (amber) — summary chip, AI affordances |
| `danger` | `#D07A62` | destructive / error |
| `warnBg` | `#332E21` | warning banner background |

Fonts: `serif` = **Newsreader** (reading canvas — subjects in the reading pane, message bodies), `ui` = **Instrument Sans** (everything else — sidebar, rows, tabs, palette, buttons). Both ship bundled (OFL) with graceful system fallback (serif → `.serif`, ui → system) if a face fails to register.

Radii: `lg` = 12, `md` = 7, `sm` = 4. Base spacing unit = 4pt.

---

## File Structure

New targets in `Package.swift`:

- **`HudsonUI`** (library) — everything testable: design system, view models, views, demo seeding, reactive-store glue. Depends on `GmailKit`, `Store`, `SyncEngine`, `GRDB`. Resources: bundled fonts.
- **`HudsonApp`** (executable) — thin `@main struct HudsonApp: App` + `AppDelegate` activation shim. Depends on `HudsonUI`.
- **`HudsonUITests`** (test) — view-model + logic + rendering tests. Depends on `HudsonUI`, `Store`.

Files:

```
Sources/Store/
  DatabaseLocation.swift        (NEW — public defaultDatabaseURL, shared by CLI + UI)
  Observation.swift             (NEW — ValueObservation twins: observeInboxThreads/observeThread/observeSplitRules/observePendingCount)
  LabelsRead.swift              (NEW — public labels(account:) read + LabelRecord)
Sources/HudsonUI/
  Theme/Palette.swift           (color tokens → Color)
  Theme/Typography.swift        (font registration + Font helpers)
  Theme/Metrics.swift           (radii, spacing, pane widths)
  Components/Keycap.swift
  Components/Chip.swift
  Components/Buttons.swift       (PrimaryButton, QuietButton)
  Components/SidebarItem.swift
  Components/InboxTab.swift
  Components/EmailRow.swift
  Components/Toast.swift
  Components/Banner.swift
  Model/AppModel.swift           (root @Observable graph: DB, account, selection, sync action)
  Model/InboxModel.swift         (observed thread rows + tabs + keyboard selection)
  Model/ThreadModel.swift        (observed thread messages + expand/collapse)
  Model/CommandModel.swift       (palette actions + fuzzy filter)
  Model/SearchModel.swift        (debounced cancellable FTS)
  Model/Triage.swift             (enqueue helpers: archive/star/toggleRead/moveToSplit)
  Model/DemoData.swift           (synthetic seed for screenshots + tests)
  Model/FuzzyMatch.swift         (subsequence scorer for palette + labels)
  Views/RootView.swift           (NavigationSplitView 3-pane assembly + key handling)
  Views/SidebarView.swift
  Views/InboxListView.swift
  Views/ThreadView.swift
  Views/CommandPaletteView.swift
  Views/SearchView.swift
  Resources/Fonts/*.ttf          (Newsreader + Instrument Sans, OFL)
Sources/HudsonApp/
  HudsonApp.swift                (@main App + AppDelegate activation)
Tests/HudsonUITests/
  ThemeTests.swift
  ObservationTests.swift         (lives here to test Store observation twins end-to-end with a UI-side seed)
  InboxModelTests.swift
  ThreadModelTests.swift
  CommandModelTests.swift
  SearchModelTests.swift
  FuzzyMatchTests.swift
  DemoDataTests.swift
  RenderSmokeTests.swift         (NSHostingView → image, best-effort; skipped if no window server)
```

Note on `Store` observation code: the `ValueObservation` twins live in `Store` (they wrap the same SQL as the existing reads and belong with them), but their end-to-end tests live in `HudsonUITests` alongside the models that consume them, so `StoreTests` stays free of UI-lifecycle concerns. A minimal `StoreTests/ObservationStoreTests.swift` covers the pure Store-level emit behavior; the UI-side test exercises the async stream.

---

## Task 1: Package scaffold, shared DB location, and a window that opens

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Store/DatabaseLocation.swift`
- Modify: `Sources/HudsonCLI/AccountsMigration.swift:5-11` (delegate `HudsonPaths.databaseURL` to the new shared location)
- Create: `Sources/HudsonApp/HudsonApp.swift`
- Create: `Sources/HudsonUI/Views/RootView.swift` (placeholder for this task)
- Create: `Sources/HudsonUI/Model/AppModel.swift` (minimal for this task)
- Test: `Tests/HudsonUITests/ThemeTests.swift` (placeholder assertion this task; real tests land in Task 2), `Tests/StoreTests/DatabaseLocationTests.swift`

**Interfaces:**
- Produces:
  - `Store.defaultDatabaseURL: URL` (public static) — `~/Library/Application Support/Hudson/hudson.sqlite`.
  - `HudsonUI.AppModel` — `@MainActor @Observable final class` with, for now, `init(databaseURL: URL)` and `init(database: HudsonDatabase, account: AccountRecord?)`; property `account: AccountRecord?`.
  - `HudsonUI.RootView: View`.
  - `HudsonApp` executable that opens a window.
- Consumes: `HudsonDatabase.open(at:)`, `HudsonDatabase.primaryAccount()`, `AccountRecord`.

- [ ] **Step 1: Add the shared database location to Store.** Create `Sources/Store/DatabaseLocation.swift`:

```swift
import Foundation

extension HudsonDatabase {
    /// The default on-disk store location, shared by the CLI and the app so
    /// both read and write the SAME mailbox: `~/Library/Application
    /// Support/Hudson/hudson.sqlite`. Kept here (not in the CLI) because the
    /// UI target needs it too, and duplicating the path in two targets is how
    /// they silently drift onto two different databases.
    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/hudson.sqlite")
    }
}
```

- [ ] **Step 2: Write the failing test for the shared location.** `Tests/StoreTests/DatabaseLocationTests.swift`:

```swift
import Foundation
import Testing
@testable import Store

@Test func defaultDatabaseURLIsUnderApplicationSupportHudson() {
    let url = HudsonDatabase.defaultDatabaseURL
    #expect(url.lastPathComponent == "hudson.sqlite")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Hudson")
    #expect(url.path.contains("Application Support"))
}
```

- [ ] **Step 3: Run it — expect FAIL** (symbol not found) before Step 1 is committed; if you did Step 1 first, temporarily confirm it compiles then passes. Run: `swift test --filter defaultDatabaseURLIsUnderApplicationSupportHudson`

- [ ] **Step 4: Point the CLI at the shared location.** In `Sources/HudsonCLI/AccountsMigration.swift`, replace the body of `HudsonPaths.databaseURL` with a delegation so there is one source of truth:

```swift
import Foundation
import Store

/// Filesystem locations the CLI uses.
enum HudsonPaths {
    /// The SQLite store, shared with the app — see `HudsonDatabase.defaultDatabaseURL`.
    static var databaseURL: URL { HudsonDatabase.defaultDatabaseURL }
}
```

- [ ] **Step 5: Add the three new targets to `Package.swift`.** Add products and targets (keep existing ones unchanged):

```swift
// in products:
.library(name: "HudsonUI", targets: ["HudsonUI"]),
.executable(name: "HudsonApp", targets: ["HudsonApp"]),

// in targets:
.target(
    name: "HudsonUI",
    dependencies: ["GmailKit", "Store", "SyncEngine",
                   .product(name: "GRDB", package: "GRDB.swift")],
    resources: [.process("Resources")]
),
.executableTarget(name: "HudsonApp", dependencies: ["HudsonUI"]),
.testTarget(name: "HudsonUITests", dependencies: ["HudsonUI", "Store"]),
```

Create an empty `Sources/HudsonUI/Resources/.gitkeep` so `.process("Resources")` has a directory (fonts arrive in Task 2). If SwiftPM errors on an empty resources dir, put a `Resources/README.md` there instead.

- [ ] **Step 6: Minimal `AppModel`.** `Sources/HudsonUI/Model/AppModel.swift`:

```swift
import Foundation
import Store

/// The root of the app's object graph. Owns the open database and the active
/// account; child models (inbox, thread, search, palette) hang off it in later
/// tasks. `@MainActor` because every view model in Hudson is main-actor —
/// SwiftUI reads them on the main thread and Store access is via async APIs, so
/// nothing here ever blocks a cooperative-pool thread.
@MainActor
@Observable
public final class AppModel {
    public let database: HudsonDatabase
    public private(set) var account: AccountRecord?

    /// Opens the store at `databaseURL` and loads the primary account. Never
    /// touches the Keychain or the network — the app is read-and-triage until
    /// the user explicitly hits "Sync now" (added in a later task).
    public init(databaseURL: URL) async throws {
        self.database = try HudsonDatabase.open(at: databaseURL)
        self.account = try await database.primaryAccount()
    }

    /// Direct-injection initializer for tests and previews (seeded in-memory DB).
    public init(database: HudsonDatabase, account: AccountRecord?) {
        self.database = database
        self.account = account
    }
}
```

- [ ] **Step 7: Placeholder `RootView`.** `Sources/HudsonUI/Views/RootView.swift`:

```swift
import SwiftUI

/// Root scene content. This task renders a placeholder so the window opens and
/// can be screenshotted; the three-pane layout replaces this body in Task 11.
public struct RootView: View {
    @State private var model: AppModel?
    private let databaseURL: URL

    public init(databaseURL: URL) { self.databaseURL = databaseURL }

    public var body: some View {
        ZStack {
            Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1A/255).ignoresSafeArea()
            Text("Hudson")
                .font(.system(size: 40, weight: .semibold, design: .serif))
                .foregroundStyle(Color(red: 0xEC/255, green: 0xEA/255, blue: 0xE4/255))
        }
        .frame(minWidth: 1040, minHeight: 680)
        .task {
            if model == nil { model = try? await AppModel(databaseURL: databaseURL) }
        }
    }
}
```

- [ ] **Step 8: The app entry point with an activation shim.** `Sources/HudsonApp/HudsonApp.swift`:

```swift
import AppKit
import HudsonUI
import Store
import SwiftUI

/// A SwiftPM-built executable launches as a background/accessory process by
/// default (no Dock icon, no key window). This delegate promotes it to a
/// regular foreground app on launch so `swift run HudsonApp` shows a real,
/// focusable window we can screenshot — the fidelity gate for the design. A
/// notarized `.app` bundle (which gets this for free from its Info.plist) is a
/// later distribution concern.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct HudsonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// `--demo` (or `HUDSON_DEMO=1`) opens a throwaway demo database instead of
    /// the real mailbox — used for screenshots and manual QA without exposing
    /// real mail. The demo DB is seeded in Task 5; until then this resolves to a
    /// temp path that simply opens empty.
    private var databaseURL: URL {
        let demo = CommandLine.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["HUDSON_DEMO"] == "1"
        return demo
            ? FileManager.default.temporaryDirectory.appending(path: "hudson-demo.sqlite")
            : HudsonDatabase.defaultDatabaseURL
    }

    var body: some Scene {
        WindowGroup {
            RootView(databaseURL: databaseURL)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
```

- [ ] **Step 9: Placeholder test file.** `Tests/HudsonUITests/ThemeTests.swift`:

```swift
import Testing
@testable import HudsonUI

@Test func hudsonUITargetLinks() {
    // Real theme tests arrive in Task 2; this proves the target builds and links.
    #expect(true)
}
```

- [ ] **Step 10: Build everything.** Run: `swift build` — expect success for all targets including `HudsonApp`. Then `swift test --filter defaultDatabaseURLIsUnderApplicationSupportHudson` and `swift test --filter hudsonUITargetLinks` — expect PASS.

- [ ] **Step 11: Verify the window opens (controller/live step).** Run: `swift run HudsonApp --demo` for a few seconds, confirm a dark window titled/badged "Hudson" appears, then quit. (This is a manual smoke; automated screenshot verification is Task 11.)

- [ ] **Step 12: Commit.**

```bash
git add Package.swift Sources/Store/DatabaseLocation.swift Sources/HudsonCLI/AccountsMigration.swift Sources/HudsonApp Sources/HudsonUI Tests/HudsonUITests Tests/StoreTests/DatabaseLocationTests.swift
git commit -m "feat(ui): scaffold HudsonUI/HudsonApp targets + shared DB location + window shell"
```

---

## Task 2: Design system — tokens, fonts, and reusable atoms

**Files:**
- Create: `Sources/HudsonUI/Theme/Palette.swift`, `Sources/HudsonUI/Theme/Typography.swift`, `Sources/HudsonUI/Theme/Metrics.swift`
- Create: `Sources/HudsonUI/Components/Keycap.swift`, `Chip.swift`, `Buttons.swift`, `SidebarItem.swift`, `InboxTab.swift`, `EmailRow.swift`, `Toast.swift`, `Banner.swift`
- Add resources: `Sources/HudsonUI/Resources/Fonts/*.ttf` (fetched by controller pre-flight — see note)
- Test: `Tests/HudsonUITests/ThemeTests.swift` (replace placeholder)

**Controller pre-flight (NOT an implementer step):** before dispatching this task, the controller places OFL font files in `Sources/HudsonUI/Resources/Fonts/` — `Newsreader` (regular, medium, semibold, italic) and `InstrumentSans` (regular, medium, semibold). If fetching fails, the task still ships with system-fallback fonts and a `// TODO(fonts)` note; fidelity is recovered later. The implementer registers whatever `.ttf`/`.otf` files exist in that directory and never hard-codes a missing file.

**Interfaces:**
- Produces:
  - `enum Palette` with `static let bgApp, bgSurface, bgSunken, bgHover, bgSelected, border, borderStrong, accent, accentInk, accentSoft, ink, inkSecondary, inkTertiary, aiBg, aiInk, danger, warnBg: Color` (all from the token table).
  - `enum Typography` with `static func register()` (idempotent CoreText registration of bundled fonts) and helpers `static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font`, `static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font`.
  - `enum Metrics` with `radiusLarge = 12.0`, `radiusMedium = 7.0`, `radiusSmall = 4.0`, `unit = 4.0`, `sidebarWidth = 224.0`, `listWidth = 384.0`.
  - Components: `Keycap(_ label: String)`, `Chip(text:role:)` with `enum ChipRole { case neutral, accent, ai, category }`, `PrimaryButton`, `QuietButton`, `SidebarItem`, `InboxTab`, `EmailRow`, `Toast`, `Banner`. Each is a `View`; exact props specified in steps.
- Consumes: nothing external.

- [ ] **Step 1: Palette.** `Sources/HudsonUI/Theme/Palette.swift` — one `Color` per token. Use an sRGB hex initializer so values are unambiguous:

```swift
import SwiftUI

/// Hudson's color tokens, lifted verbatim from the Pencil Design System frame.
/// One name per token — views reference `Palette.accent`, never a raw hex — so
/// a future theme change is one edit here.
public enum Palette {
    public static let bgApp        = Color(hex: 0x1C1C1A)
    public static let bgSurface    = Color(hex: 0x242422)
    public static let bgSunken     = Color(hex: 0x171716)
    public static let bgHover      = Color(hex: 0x2B2B28)
    public static let bgSelected   = Color(hex: 0x2C3530)
    public static let border       = Color(hex: 0x32322E)
    public static let borderStrong = Color(hex: 0x474640)
    public static let accent       = Color(hex: 0x8FB5A5)
    public static let accentInk    = Color(hex: 0x16211D)
    public static let accentSoft   = Color(hex: 0x2A362F)
    public static let ink          = Color(hex: 0xECEAE4)
    public static let inkSecondary = Color(hex: 0xA29E95)
    public static let inkTertiary  = Color(hex: 0x6E6B64)
    public static let aiBg         = Color(hex: 0x2E2A20)
    public static let aiInk        = Color(hex: 0xC7AC72)
    public static let danger       = Color(hex: 0xD07A62)
    public static let warnBg       = Color(hex: 0x332E21)
}

extension Color {
    /// 0xRRGGBB → sRGB Color. Kept internal to the theme; views use named tokens.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
```

- [ ] **Step 2: Write the failing theme test.** Replace `Tests/HudsonUITests/ThemeTests.swift`:

```swift
import SwiftUI
import Testing
@testable import HudsonUI

@MainActor
@Test func accentTokenResolvesToPencilGreen() {
    let resolved = Palette.accent.resolve(in: EnvironmentValues())
    #expect(abs(Double(resolved.red)   - 0x8F/255.0) < 0.01)
    #expect(abs(Double(resolved.green) - 0xB5/255.0) < 0.01)
    #expect(abs(Double(resolved.blue)  - 0xA5/255.0) < 0.01)
}

@Test func metricsMatchPencilRadii() {
    #expect(Metrics.radiusLarge == 12)
    #expect(Metrics.radiusMedium == 7)
    #expect(Metrics.radiusSmall == 4)
}
```

- [ ] **Step 3: Run it — expect FAIL** (Palette/Metrics not defined). Run: `swift test --filter accentTokenResolvesToPencilGreen`

- [ ] **Step 4: Metrics + Typography.** `Metrics.swift` per the Interfaces block. `Typography.swift`:

```swift
import CoreText
import SwiftUI

/// Bundled-font registration + font helpers. `register()` is idempotent and
/// safe to call more than once (CoreText returns an already-registered error we
/// swallow). If a face fails to register or is absent, `serif`/`ui` fall back to
/// the system serif / system font so the app still renders — fidelity degrades,
/// nothing crashes.
public enum Typography {
    private static var didRegister = false

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
```

(This needs `import AppKit` for `NSFont`. Weight selection on a variable font is best-effort — `.weight()` maps to the CoreText weight trait; if a weight does not render distinctly the typeface is still correct, which is the fidelity that matters. Ground-truth family names above were confirmed by the controller from the bundled files' `name` tables; the candidate-probe means the code stays correct even if a face is later re-instanced under a different name.)

- [ ] **Step 5: Run the theme test — expect PASS.** Run: `swift test --filter "accentTokenResolvesToPencilGreen|metricsMatchPencilRadii"`

- [ ] **Step 6: Build the atoms.** Implement each component as a small focused `View`. Exact specs (derive spacing from `Metrics.unit`):

  - **`Keycap(_ label: String)`** — monospaced-ish `Typography.ui(11, .medium)`, `inkSecondary` on `bgSunken`, `1pt` `border`, `radiusSmall`, padding `2×5`. Renders keys like `⌘K`, `E`, `↵`.
  - **`Chip(text:role:)`** — `Typography.ui(11, .medium)`, `radiusSmall`, padding `2×6`. Roles: `.neutral` (inkSecondary on bgHover), `.accent` (accentInk on accent), `.ai` (aiInk on aiBg), `.category` (inkSecondary on accentSoft).
  - **`PrimaryButton(title:action:)`** — accentInk on accent fill, `radiusMedium`, `Typography.ui(13, .semibold)`, padding `6×12`, hover darkens ~6%.
  - **`QuietButton(title:action:)`** — ink on `.clear`, hover `bgHover`, `radiusMedium`, same metrics.
  - **`SidebarItem(icon:title:count:isSelected:action:)`** — row, `radiusMedium`, selected = `accentSoft` bg + `ink` text; unselected = `inkSecondary`; optional trailing count in `inkTertiary`. `Typography.ui(13, .medium)`.
  - **`InboxTab(title:count:isActive:action:)`** — pill; active = `ink` text with a `2pt accent` underline/indicator; inactive = `inkTertiary`. `Typography.ui(12, .semibold)`.
  - **`EmailRow(row:isSelected:isUnread:)`** where `row` is a lightweight display struct (`EmailRowData`: `fromSummary, subject, snippet, timeText, hasAttachment, category, unread`) so the component has no Store dependency — the list maps `ThreadRow` → `EmailRowData`. Layout: leading unread dot (6pt `accent`, hidden if read), then a vertical stack: line 1 = `fromSummary` (`Typography.ui(13, unread ? .semibold : .medium)`, `ink`) + trailing `timeText` (`inkTertiary`, `Typography.ui(11)`); line 2 = `subject` (`Typography.ui(13, unread ? .semibold : .regular)`, `ink`); line 3 = `snippet` (`Typography.ui(12)`, `inkSecondary`, one line, truncated) + trailing paperclip if `hasAttachment` + `Chip` if `category` non-empty. Selected row: `bgSelected` fill + `2pt accent` leading bar; row height ~72pt; horizontal padding `12`, vertical `8`.
  - **`Toast(text:)`** — `bgSunken`, `borderStrong` hairline, `radiusMedium`, `ink`, shadow; used for undo confirmations later.
  - **`Banner(text:role:)`** — full-width strip; `.warn` = `warnBg`/`aiInk`, `.error` = `warnBg`/`danger`. Used for offline/sync-error state.

- [ ] **Step 7: Add a render-smoke test that the atoms build a hosting view.** Append to `ThemeTests.swift`:

```swift
@MainActor
@Test func atomsComposeIntoAHostingView() {
    let stack = VStack {
        Keycap("⌘K")
        Chip(text: "Promotions", role: .category)
        InboxTab(title: "Important", count: 12, isActive: true, action: {})
        EmailRow(row: .init(fromSummary: "Ada Lovelace", subject: "Re: Analytical Engine",
                            snippet: "The numbers are ready.", timeText: "9:41",
                            hasAttachment: true, category: "updates", unread: true),
                 isSelected: true, isUnread: true)
    }
    let host = NSHostingView(rootView: stack)
    host.layout()
    #expect(host.fittingSize.width > 0)
    #expect(host.fittingSize.height > 0)
}
```

- [ ] **Step 8: Run all theme tests — expect PASS.** Run: `swift test --filter ThemeTests`

- [ ] **Step 9: Commit.**

```bash
git add Sources/HudsonUI/Theme Sources/HudsonUI/Components Sources/HudsonUI/Resources/Fonts Tests/HudsonUITests/ThemeTests.swift
git commit -m "feat(ui): design system — color/type/metric tokens + reusable atoms"
```

---

## Task 3: Reactive read layer — `ValueObservation` twins in Store

**Files:**
- Create: `Sources/Store/Observation.swift`
- Create: `Sources/Store/LabelsRead.swift`
- Test: `Tests/StoreTests/ObservationStoreTests.swift`, `Tests/HudsonUITests/ObservationTests.swift`

**Interfaces:**
- Produces (all on `HudsonDatabase`):
  - `func observeInboxThreads(account: String, split: String?, limit: Int) -> AsyncValueObservation<[ThreadRow]>` — emits the current inbox page immediately, then re-emits on any change to `thread_rollup`/`mutation_queue` that affects it. Same SELECT as `inboxThreads` (minus keyset paging — the observed list is the first `limit` rows; paging deeper stays on the one-shot `inboxThreads`).
  - `func observeThread(threadID: String, account: String) -> AsyncValueObservation<[MessageRow]>` — same SELECT as `threadMessages`, re-emitting on label/body changes.
  - `func observeSplitRules(account: String) -> AsyncValueObservation<[SplitRule]>`.
  - `func observePendingCount(account: String) -> AsyncValueObservation<Int>` — `COUNT(*)` of `mutation_queue` for the account (drives the "N pending / syncing" indicator).
  - `struct LabelRecord: Sendable, Equatable { public let id: String; public let name: String }` and `func labels(account: String) async throws -> [LabelRecord]` — user + system labels for the sidebar, ordered by name. (The `labels` table has exactly `account_email, id, name` — PK `(account_email, id)` — confirmed against `Migrations.swift:151`; there is NO `type` column, so the sidebar distinguishes system vs user labels by the id prefix / known-system-id set, not a stored type.)
- Consumes: existing tables `thread_rollup`, `messages`, `message_labels`, `mutation_queue`, `split_rules`, `labels`.

Use GRDB's `ValueObservation.tracking { db in ... }` and expose it as an `AsyncValueObservation` via `.values(in: writer)`. Region tracking is automatic — `ValueObservation` observes exactly the tables the closure reads, so an `enqueueMutation` (which writes `mutation_queue` and `thread_rollup`) triggers a re-emit of `observeInboxThreads` for free.

- [ ] **Step 1: Write the failing Store-level observation test.** `Tests/StoreTests/ObservationStoreTests.swift`:

```swift
import GRDB
import Testing
@testable import Store

@Test func observeInboxThreadsEmitsThenReemitsAfterArchive() async throws {
    let db = try HudsonDatabase.inMemory()
    try await TestSeed.account(db, "a@b.com")
    try await TestSeed.inboxThread(db, account: "a@b.com", threadID: "t1",
                                   messageID: "m1", subject: "Hello")

    var iterator = db.observeInboxThreads(account: "a@b.com", split: nil, limit: 50)
        .makeAsyncIterator()

    let first = try await iterator.next()
    #expect(first?.contains { $0.threadID == "t1" } == true)

    // Optimistic archive: remove INBOX. enqueueMutation recomputes the rollup
    // in-transaction, so the observation must re-emit without "t1".
    try await db.enqueueMutation(messageID: "m1", labelID: "INBOX", op: .remove,
                                 account: "a@b.com", now: 1)
    let second = try await iterator.next()
    #expect(second?.contains { $0.threadID == "t1" } == false)
}
```

(The implementer adds a small `TestSeed` helper in `Tests/StoreTests/Support/TestSeed.swift` if one does not already exist — a thin wrapper that inserts an account + one hydrated inbox message + rollup via the existing `applySnapshotInTransaction`/write APIs. Reuse whatever seeding the existing `InboxQueryTests`/`ThreadRollupTests` already use rather than inventing a new path.)

- [ ] **Step 2: Run it — expect FAIL** (`observeInboxThreads` undefined). Run: `swift test --filter observeInboxThreadsEmitsThenReemitsAfterArchive`

- [ ] **Step 3: Implement `Observation.swift`.** Each method builds a `ValueObservation` over the same SQL as its one-shot twin. Example shape (implementer completes the other three analogously):

```swift
import GRDB

extension HudsonDatabase {
    public func observeInboxThreads(
        account: String, split: String?, limit: Int
    ) -> AsyncValueObservation<[ThreadRow]> {
        ValueObservation
            .tracking { db -> [ThreadRow] in
                var sql = """
                    SELECT thread_id, last_message_id, subject, snippet, from_summary,
                           split_key, category, last_message_at, message_count,
                           unread, in_inbox, has_attachment
                    FROM thread_rollup
                    WHERE account_email = ? AND in_inbox = 1
                    """
                var arguments: StatementArguments = [account]
                if let split { sql += " AND split_key = ?"; arguments += [split] }
                sql += " ORDER BY last_message_at DESC, thread_id DESC LIMIT ?"
                arguments += [limit]
                return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.threadRow(from:))
            }
            .values(in: writer)
    }
}
```

(Keep the SELECT byte-for-byte aligned with `InboxQuery.inboxThreads` so the two never drift — a comment on each observation method points at its one-shot twin. `observeThread` mirrors `AIStore.threadMessages`; `observeSplitRules` mirrors `splitRules`; `observePendingCount` is `SELECT COUNT(*) FROM mutation_queue WHERE account_email = ?`.)

- [ ] **Step 4: Implement `LabelsRead.swift`** — `LabelRecord` + `labels(account:)` reading `SELECT id, name FROM labels WHERE account_email = ? ORDER BY name` (the `labels` table is `account_email, id, name` — no `type` column; confirmed at `Migrations.swift:151`).

- [ ] **Step 5: Run the Store test — expect PASS.** Run: `swift test --filter observeInboxThreadsEmitsThenReemitsAfterArchive`

- [ ] **Step 6: Write the UI-side async-stream test.** `Tests/HudsonUITests/ObservationTests.swift` — subscribe to `observeThread`, assert the initial emit contains the seeded messages, then mark one read via `enqueueMutation(... UNREAD remove ...)` and assert a re-emit. This proves the async stream works from a consumer's vantage (the models will consume it identically).

- [ ] **Step 7: Run it — expect PASS.** Run: `swift test --filter ObservationTests`

- [ ] **Step 8: Commit.**

```bash
git add Sources/Store/Observation.swift Sources/Store/LabelsRead.swift Tests/StoreTests/ObservationStoreTests.swift Tests/StoreTests/Support Tests/HudsonUITests/ObservationTests.swift
git commit -m "feat(store): ValueObservation twins (inbox/thread/splits/pending) + labels read"
```

---

## Task 4: Demo data seed

**Files:**
- Create: `Sources/HudsonUI/Model/DemoData.swift`
- Test: `Tests/HudsonUITests/DemoDataTests.swift`

**Why before the views:** the sidebar, list, and reading views are all built and screenshotted against this seed, and the model tests reuse it. Seeding through the real write path (not raw INSERTs) also proves the views render exactly what sync produces.

**Interfaces:**
- Produces: `enum DemoData { public static func seed(into database: HudsonDatabase, account: String = "you@hudson.app") async throws }` — inserts ~40 synthetic threads across splits `primary`/`important`/`team`/`news` and Gmail categories `updates`/`promotions`/`social`, a mix of read/unread, some multi-message threads, some with attachments and bodies. All content is invented (no real names/addresses). Also inserts the `account` row and a few `split_rules` so the split tabs populate.
- Consumes: existing write APIs — `upsertAccount`, the snapshot-apply path used by `SyncEngine` (`applySnapshotInTransaction`/`applySnapshots`), `saveBody`, `setSplitRules`. Reuse the same seeding primitives the Store tests use; do NOT hand-write rollup rows — go through the maintaining path so `thread_rollup` is built correctly.

- [ ] **Step 1: Write the failing test.** `Tests/HudsonUITests/DemoDataTests.swift`:

```swift
import Store
import Testing
@testable import HudsonUI

@Test func demoSeedPopulatesInboxAcrossSplits() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")

    let all = try await db.inboxThreads(account: "you@hudson.app", split: nil, limit: 100)
    #expect(all.count >= 20)

    let splits = Set(all.map(\.splitKey))
    #expect(splits.contains("important"))
    #expect(all.contains { $0.unread })
    #expect(all.contains { $0.hasAttachment })
}
```

- [ ] **Step 2: Run it — expect FAIL.** Run: `swift test --filter demoSeedPopulatesInboxAcrossSplits`
- [ ] **Step 3: Implement `DemoData.seed`.** Build synthetic `MessageSnapshot`s (invented sender display names, subjects, snippets, bodies, label sets including `INBOX`, `UNREAD` on some, `CATEGORY_*` on some, `SENT` on a couple) and apply them through the same transaction path `SyncEngine` uses, then `saveBody` for the ones with bodies, then `setSplitRules` with a couple of sender/domain rules that route some threads to `important`/`team`. Keep the data cohesive and realistic (a believable demo inbox), but 100% fictional.
- [ ] **Step 4: Run it — expect PASS.** Run: `swift test --filter demoSeedPopulatesInboxAcrossSplits`
- [ ] **Step 5: Wire `--demo` to seed on first open.** In `AppModel`, add `public static func demo() async throws -> AppModel` that opens the temp demo DB, seeds it if empty (guard on `inboxThreads(...).isEmpty`), and returns a model. Update `HudsonApp`/`RootView` so `--demo` uses `AppModel.demo()`. Add a test that `AppModel.demo()` yields a model whose account is non-nil.
- [ ] **Step 6: Commit.**

```bash
git add Sources/HudsonUI/Model/DemoData.swift Sources/HudsonUI/Model/AppModel.swift Tests/HudsonUITests/DemoDataTests.swift
git commit -m "feat(ui): synthetic demo mailbox seed for screenshots + model tests"
```

---

## Task 5: InboxModel — observed rows, split tabs, keyboard selection

**Files:**
- Create: `Sources/HudsonUI/Model/InboxModel.swift`
- Create: `Sources/HudsonUI/Model/Triage.swift`
- Test: `Tests/HudsonUITests/InboxModelTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class InboxModel` with:
    - `init(database: HudsonDatabase, account: String)`
    - `private(set) var rows: [ThreadRow]`
    - `private(set) var tabs: [SplitTab]` where `struct SplitTab: Identifiable, Sendable, Equatable { let key: String; let title: String; let count: Int }` — derived from the split rules + the categories actually present, always including a leading `primary` tab titled "Primary".
    - `var activeSplit: String?` (nil = all inbox; setting it re-subscribes the observation)
    - `var selectedThreadID: String?`
    - `func start() async` — begins observing `observeInboxThreads` for the active split and `observeSplitRules`; cancels/re-subscribes when `activeSplit` changes.
    - `func selectNext()` / `func selectPrevious()` — move `selectedThreadID` within `rows` (the j/k logic), clamping at ends, selecting the first row if nothing is selected.
    - `func archiveSelected()`, `func toggleStarSelected()`, `func toggleReadSelected()` — resolve the selected `ThreadRow.lastMessageID` and call the matching `Triage` helper.
  - `enum Triage` (in `Triage.swift`): `static func archive(messageID:account:database:) async throws` (`enqueueMutation INBOX remove`), `star`/`unstar` (`STARRED add/remove`), `markRead`/`markUnread` (`UNREAD remove/add`), `moveToSplit` (label add for a user-defined split label — for v1, `moveToSplit` is a stub that no-ops with a `// TODO(M?)` since splits are rule-derived, not label-moves; keep the signature so the palette can call it). Each computes `now = Int64(Date().timeIntervalSince1970 * 1000)`.
- Consumes: `observeInboxThreads`, `observeSplitRules`, `enqueueMutation`, `ThreadRow`, `SplitRule`.

- [ ] **Step 1: Failing test for j/k selection + archive drop.** `Tests/HudsonUITests/InboxModelTests.swift`:

```swift
import Store
import Testing
@testable import HudsonUI

@MainActor
@Test func selectNextAdvancesAndArchiveRemovesSelectedThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: "you@hudson.app")
    let model = InboxModel(database: db, account: "you@hudson.app")
    await model.start()
    // let the first observation emit
    try await Task.sleep(for: .milliseconds(50))

    #expect(!model.rows.isEmpty)
    model.selectNext()
    let firstSelected = model.selectedThreadID
    #expect(firstSelected != nil)
    model.selectNext()
    #expect(model.selectedThreadID != firstSelected)

    // Archive the selected thread; after the re-emit it is gone from rows.
    model.selectPrevious()
    let target = model.selectedThreadID
    try await model.archiveSelected()
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.rows.contains { $0.threadID == target } == false)
}
```

- [ ] **Step 2: Run it — expect FAIL.** Run: `swift test --filter selectNextAdvancesAndArchiveRemovesSelectedThread`
- [ ] **Step 3: Implement `Triage.swift`** then `InboxModel`. The observation subscription runs in a `Task` stored on the model; `start()` (re)creates it. Deriving `tabs`: read split rules + `SELECT DISTINCT split_key, category` presence via a one-shot count per split (or compute counts from the full `inboxThreads(split:nil)` list grouped by `splitKey`). Keep tab titles Title-cased (`important` → "Important", `updates` → "Updates").
- [ ] **Step 4: Run it — expect PASS.** Run: `swift test --filter selectNextAdvancesAndArchiveRemovesSelectedThread`
- [ ] **Step 5: Add tests** for: `activeSplit` filters rows to one split; `toggleReadSelected` flips unread and re-emits; empty-inbox yields empty rows + a Primary tab with count 0. Run: `swift test --filter InboxModelTests`
- [ ] **Step 6: Commit.**

```bash
git add Sources/HudsonUI/Model/InboxModel.swift Sources/HudsonUI/Model/Triage.swift Tests/HudsonUITests/InboxModelTests.swift
git commit -m "feat(ui): InboxModel — observed rows, split tabs, j/k selection, optimistic triage"
```

---

## Task 6: ThreadModel — observed thread, expand/collapse

**Files:**
- Create: `Sources/HudsonUI/Model/ThreadModel.swift`
- Test: `Tests/HudsonUITests/ThreadModelTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class ThreadModel` with `init(database:account:)`, `private(set) var messages: [ThreadMessage]` where `struct ThreadMessage: Identifiable, Sendable, Equatable { let row: MessageRow; let bodyText: String?; var isExpanded: Bool }`, `func open(threadID: String) async` (subscribes `observeThread` + loads bodies for expanded messages via `message(id:account:)`), `func toggleExpanded(_ id: String)`, and a computed `subject`/`participants` header derived from the newest message. Newest message starts expanded; older ones collapsed (Superhuman-style).
- Consumes: `observeThread`, `message(id:account:)`, `MessageRow`.

- [ ] **Step 1: Failing test.** Seed a two-message thread, `open` it, assert `messages.count == 2`, newest `isExpanded == true`, and that toggling collapses/expands. Then mark-unread the thread and assert the observation re-emits with the updated label state.
- [ ] **Step 2: Run — expect FAIL.** Run: `swift test --filter ThreadModelTests`
- [ ] **Step 3: Implement `ThreadModel`.** Bodies load lazily: on open and on expand, fetch `message(id:account:)` for the expanded ids and cache the plain text on the `ThreadMessage`. Keep the observation for label/message changes; bodies are fetched imperatively (they don't change once hydrated).
- [ ] **Step 4: Run — expect PASS.** Run: `swift test --filter ThreadModelTests`
- [ ] **Step 5: Commit.**

```bash
git add Sources/HudsonUI/Model/ThreadModel.swift Tests/HudsonUITests/ThreadModelTests.swift
git commit -m "feat(ui): ThreadModel — observed thread messages, lazy bodies, expand/collapse"
```

---

## Task 7: FuzzyMatch + CommandModel (⌘K palette actions)

**Files:**
- Create: `Sources/HudsonUI/Model/FuzzyMatch.swift`
- Create: `Sources/HudsonUI/Model/CommandModel.swift`
- Test: `Tests/HudsonUITests/FuzzyMatchTests.swift`, `Tests/HudsonUITests/CommandModelTests.swift`

**Interfaces:**
- Produces:
  - `enum FuzzyMatch { static func score(_ candidate: String, query: String) -> Int? }` — subsequence match, `nil` if `query` is not a subsequence of `candidate` (case-insensitive); higher score for contiguous / word-boundary / prefix matches. Empty query scores every candidate at 0 (all shown, original order).
  - `struct Command: Identifiable, Sendable { let id: String; let title: String; let subtitle: String?; let keys: [String]; let kind: CommandKind }`, `enum CommandKind { case archive, toggleStar, toggleRead, snooze, moveToSplit(String), openSearch, switchSplit(String) }`.
  - `@MainActor @Observable final class CommandModel` with `var query: String`, `private(set) var results: [Command]`, `func reload(splits: [SplitTab], hasSelection: Bool)` (builds the base command list — triage commands enabled only when `hasSelection`), and `func filter()` (recomputes `results` from `query` via `FuzzyMatch`, best-score-first). The palette view calls a `perform(_ command: Command)` closure the host supplies (dispatch lives in `RootView`, Task 11).
- Consumes: `SplitTab` (from InboxModel).

- [ ] **Step 1: Failing FuzzyMatch tests.** `"archive"` matches query `"arc"` and `"ave"` (subsequence) but not `"xyz"`; `"Archive"` ranks above `"Move to Archive"` for query `"arch"` (prefix beats mid-string); empty query returns a score for everything. Run: `swift test --filter FuzzyMatchTests`
- [ ] **Step 2: Run — expect FAIL,** then implement `FuzzyMatch`, then PASS.
- [ ] **Step 3: Failing CommandModel tests.** With a selection, `results` includes Archive/Star/Mark read; without a selection those are absent (or disabled — pick disabled-and-filtered-out for v1 and assert absence). Typing `"imp"` surfaces the "Switch to Important" split command. Run: `swift test --filter CommandModelTests`
- [ ] **Step 4: Run — expect FAIL,** then implement `CommandModel`, then PASS.
- [ ] **Step 5: Commit.**

```bash
git add Sources/HudsonUI/Model/FuzzyMatch.swift Sources/HudsonUI/Model/CommandModel.swift Tests/HudsonUITests/FuzzyMatchTests.swift Tests/HudsonUITests/CommandModelTests.swift
git commit -m "feat(ui): fuzzy matcher + CommandModel for the ⌘K palette"
```

---

## Task 8: SearchModel — debounced cancellable FTS

**Files:**
- Create: `Sources/HudsonUI/Model/SearchModel.swift`
- Test: `Tests/HudsonUITests/SearchModelTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class SearchModel` with `var query: String`, `var scope: SearchScope` (`.all`/`.inbox`), `private(set) var hits: [SearchHit]`, `private(set) var isSearching: Bool`, and `func queryChanged()` — debounces ~150ms, cancels any in-flight search (store the `Task`, cancel on each new keystroke), enforces the 2-char floor (clears hits below it without hitting the DB), and calls `searchMessages(account:query:limit:scope:)`. Selecting a hit is handled by the host (opens the thread).
- Consumes: `searchMessages`, `SearchHit`, `SearchScope`.

- [ ] **Step 1: Failing test.** Seed messages whose bodies contain a distinctive token; set `query` to a 1-char string → `hits` stays empty and no search runs; set a 3-char prefix of the token → after the debounce, `hits` is non-empty and contains the expected message; rapidly change the query and assert only the final query's results land (cancellation). Use a small injected debounce interval to keep the test fast, or expose the interval as an init parameter defaulting to 150ms and pass ~10ms in tests. Run: `swift test --filter SearchModelTests`
- [ ] **Step 2: Run — expect FAIL,** then implement `SearchModel`, then PASS.
- [ ] **Step 3: Commit.**

```bash
git add Sources/HudsonUI/Model/SearchModel.swift Tests/HudsonUITests/SearchModelTests.swift
git commit -m "feat(ui): SearchModel — debounced, cancellable, floor-guarded FTS"
```

---

## Task 9: SidebarView + InboxListView

**Files:**
- Create: `Sources/HudsonUI/Views/SidebarView.swift`, `Sources/HudsonUI/Views/InboxListView.swift`
- Test: `Tests/HudsonUITests/RenderSmokeTests.swift` (create; hosting-view render smoke, best-effort)

**Design (from Pencil main window `tZpp6`):**
- **Sidebar** (`Metrics.sidebarWidth ≈ 224`, `bgSunken` base): top padding leaves room for the window's traffic lights; account/wordmark row; a primary nav group — `SidebarItem` rows "Inbox" (with total unread count), "Starred", "Snoozed", "Sent"; a "SPLITS" section header (`Typography.ui(11, .semibold)`, `inkTertiary`, uppercase, letter-spaced) listing the split tabs as sidebar items; a "LABELS" section from `labels(account:)`; a footer row showing sync/pending state (from `observePendingCount`) and a settings affordance. Selected item uses `accentSoft` + `ink`.
- **Inbox list** (`Metrics.listWidth ≈ 384`, `bgApp`): a top bar with the split `InboxTab`s (horizontally scrollable if they overflow) and the active count; below it a `List`/`ScrollView` of `EmailRow`s mapped from `InboxModel.rows`. Selection binds to `InboxModel.selectedThreadID`; clicking a row selects it and opens it in the reading pane. Keyset pagination: when the last row appears, call `inboxThreads(before:)` to append the next page (observed first page + appended tail is acceptable for v1; keep it simple — a "load more" on scroll-to-bottom).

- [ ] **Step 1: Implement `SidebarView`** driven by an injected `AppModel`/`InboxModel` (pass the derived data in; the view owns no Store calls). Section headers, items, counts, footer.
- [ ] **Step 2: Implement `InboxListView`** — tabs bound to `InboxModel.activeSplit`, rows from `InboxModel.rows` mapped to `EmailRowData`, selection highlight, click-to-open, scroll-to-bottom "load more".
- [ ] **Step 3: Render smoke test.** `RenderSmokeTests.swift` builds each view with a seeded in-memory `AppModel`/`InboxModel`, wraps in `NSHostingView`, calls `layout()`, and asserts a positive fitting size. Guard the test so it no-ops cleanly if there is no window server (`NSApp == nil` path) — wrap the body and `#expect(true)` when rendering is unavailable, so CI without a display still passes:

```swift
@MainActor
@Test func sidebarAndListRenderWithSeededData() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let inbox = InboxModel(database: db, account: "you@hudson.app")
    await inbox.start()
    try await Task.sleep(for: .milliseconds(50))
    let host = NSHostingView(rootView: InboxListView(inbox: inbox, onOpen: { _ in }))
    host.frame = .init(x: 0, y: 0, width: 384, height: 700)
    host.layout()
    #expect(host.fittingSize.width > 0)
}
```

- [ ] **Step 4: Run** `swift test --filter RenderSmokeTests` — expect PASS.
- [ ] **Step 5: Commit.**

```bash
git add Sources/HudsonUI/Views/SidebarView.swift Sources/HudsonUI/Views/InboxListView.swift Tests/HudsonUITests/RenderSmokeTests.swift
git commit -m "feat(ui): sidebar + split-tab inbox list views"
```

---

## Task 10: ThreadView + CommandPaletteView + SearchView

**Files:**
- Create: `Sources/HudsonUI/Views/ThreadView.swift`, `Sources/HudsonUI/Views/CommandPaletteView.swift`, `Sources/HudsonUI/Views/SearchView.swift`
- Test: extend `Tests/HudsonUITests/RenderSmokeTests.swift`

**Design (from Pencil `tZpp6`, `j47C5Z`, `mqRfa`):**
- **ThreadView** (`bgSurface`): a top toolbar with icon buttons (Archive, Snooze [placeholder], Star, ⋯) using `QuietButton`; the subject in `Typography.serif(24, .semibold)` `ink`; a sender row (circular initial avatar in `accentSoft`, name in `ink`, address in `inkSecondary`, time in `inkTertiary`); the **AI summary chip** — a pill in `aiBg`/`aiInk` reading "✦ Summarize thread" that, in this milestone, is a NON-FUNCTIONAL placeholder (no network; tapping shows a Toast "AI summaries arrive with M7" or is simply disabled) — this satisfies the privacy constraint (no egress) while placing the surface exactly where the design shows it; the message body in `Typography.serif(15)` `ink` at a comfortable reading measure (max width ~680); attachment chips; and a bottom reply bar that is a disabled affordance (composer is M5) — a `QuietButton` "Reply" that shows a Toast "Sending arrives with M5". Collapsed older messages render as one-line summaries that expand on click (via `ThreadModel.toggleExpanded`).
- **CommandPaletteView** (centered modal, `bgSunken`, `radiusLarge`, `borderStrong`, shadow, width ~560): a search field bound to `CommandModel.query`; a list of `Command` rows (icon + title + `subtitle` + trailing `Keycap`s); arrow keys move a highlighted index, `↵` performs it, `Esc` closes. Filtered live via `CommandModel.filter()`.
- **SearchView** (overlay or list-region replacement): a search field bound to `SearchModel.query` with a scope toggle (All / Inbox); results as compact rows (subject, from, snippet, date) from `SearchModel.hits`; selecting opens the thread. Debounce/cancel already live in `SearchModel`.

- [ ] **Step 1: Implement `ThreadView`** bound to a `ThreadModel`, with the AI + reply placeholders wired to Toasts (no network, no send).
- [ ] **Step 2: Implement `CommandPaletteView`** bound to a `CommandModel` with keyboard navigation and a `perform` closure.
- [ ] **Step 3: Implement `SearchView`** bound to a `SearchModel` with scope toggle and an `onOpen` closure.
- [ ] **Step 4: Extend render smoke tests** to host each of the three views with seeded models; assert positive fitting sizes. Run: `swift test --filter RenderSmokeTests`
- [ ] **Step 5: Commit.**

```bash
git add Sources/HudsonUI/Views/ThreadView.swift Sources/HudsonUI/Views/CommandPaletteView.swift Sources/HudsonUI/Views/SearchView.swift Tests/HudsonUITests/RenderSmokeTests.swift
git commit -m "feat(ui): reading pane + command palette + search views"
```

---

## Task 11: RootView assembly, global keyboard map, live run + screenshot verification, docs

**Files:**
- Modify: `Sources/HudsonUI/Views/RootView.swift` (replace placeholder with the real 3-pane)
- Modify: `Sources/HudsonUI/Model/AppModel.swift` (own child models + selection + palette/search presentation state + optional "Sync now")
- Create: `docs/ui/running-the-app.md`
- Modify: `README.md` (add a "Run the app" section)
- Test: `Tests/HudsonUITests/RenderSmokeTests.swift` (full RootView render smoke)

**Interfaces:**
- `AppModel` gains: `inbox: InboxModel`, `thread: ThreadModel`, `command: CommandModel`, `search: SearchModel`; presentation flags `isPaletteVisible`, `isSearchVisible`; `func openThread(_ id: String)`; `func perform(_ command: Command)`; and `func syncNow() async` that, IF Keychain credentials resolve (reuse `Runtime.bootstrap`-style wiring, moved into a small `HudsonUI` helper or called through a thin seam), runs one `engine` poll + `flusher.flushOnce()` + retire, else surfaces a Banner "Connect an account in Terminal: `hudson auth`". Sync must never block the UI — it runs in a `Task` and updates state on completion.

- [ ] **Step 1: Compose the 3-pane.** Replace `RootView.body` with a `NavigationSplitView(sidebar: { SidebarView(...) }, content: { InboxListView(...) }, detail: { ThreadView(...) })`, `bgApp` window background, `.windowStyle(.hiddenTitleBar)` already set on the scene. Overlay the `CommandPaletteView` when `isPaletteVisible` and `SearchView` when `isSearchVisible`.
- [ ] **Step 2: Global keyboard map.** Install key handlers (via `.onKeyPress` on a focused container, or a lightweight `NSEvent` local monitor in an `AppKit` representable): `j`/`k` → `inbox.selectNext()`/`selectPrevious()`; `↵`/`o` → open selected; `e` → `inbox.archiveSelected()`; `s` → `toggleStarSelected()`; `u` → `toggleReadSelected()`; `⌘K` → toggle palette; `⌘F`/`/` → toggle search; `Esc` → dismiss palette/search or clear selection. Every triage key routes through the model → `enqueueMutation` (instant, observed). Document the map in a `KeyboardMap` value so it is testable and so a future keyboard-overlay screen (Pencil `NAx8S`) can render from it.
- [ ] **Step 3: Full render smoke test.** Host the assembled `RootView` (seeded demo `AppModel`) in an `NSHostingView` at 1200×760, `layout()`, assert positive fitting size and no crash. Run: `swift test --filter RenderSmokeTests`
- [ ] **Step 4: Run the whole suite.** Run: `swift test` — expect ALL green (existing 273 + new). Fix any regressions before proceeding.
- [ ] **Step 5: LIVE RUN + SCREENSHOT (controller fidelity gate).** Build and launch the demo app, capture the window, and compare against the Pencil screens:

```bash
swift build
swift run HudsonApp --demo &   # launches the seeded demo mailbox
# wait for the window, then capture the frontmost window:
screencapture -o -l "$(GetWindowID Hudson 2>/dev/null)" scratchpad/hudson-main.png \
  || screencapture -o scratchpad/hudson-main.png
```

The controller opens `scratchpad/hudson-main.png` and compares it side-by-side with the Pencil main window, palette, and search screenshots, then files any fidelity gaps as findings for a fix round. (This step is inherently manual — a SwiftUI Mac app's visual fidelity cannot be asserted headlessly; the render-smoke tests prove it renders, the eyeball proves it matches.)

- [ ] **Step 6: Docs.** Write `docs/ui/running-the-app.md` (how to `swift run HudsonApp`, `--demo`, the keyboard map, what's stubbed until M5/M7) and add a short "Run the app" section to `README.md`.
- [ ] **Step 7: Commit.**

```bash
git add Sources/HudsonUI/Views/RootView.swift Sources/HudsonUI/Model/AppModel.swift docs/ui/running-the-app.md README.md Tests/HudsonUITests/RenderSmokeTests.swift
git commit -m "feat(ui): assemble 3-pane RootView, global keyboard map, run docs"
```

---

## Self-Review

**Spec coverage vs. the UI directive (`hudson-ui-directive` memory) + architecture doc "UI — SwiftUI shell":**
- Inbox list (rollup-backed, split tabs incl. Gmail categories) → Tasks 3, 5, 9. ✓
- Thread reading view → Tasks 6, 10. ✓
- Keyboard-first triage (j/k/e/s/u) → Tasks 5, 11. ✓
- Command palette (⌘K) → Tasks 7, 10, 11. ✓
- Search → Tasks 8, 10, 11. ✓
- Instant optimistic triage from the overlay (<16ms feel) → `enqueueMutation` path, Tasks 3/5. ✓
- Reactive reads via `ValueObservation` over overlay-merged effective state → Task 3. ✓
- Composer deferred (needs M5), AI surfaces deferred (needs M7) → placeholders in Task 10, explicitly non-functional to honor privacy. ✓
- "Test everything": ViewModel/logic tests every task (hard gate) + render-smoke + live screenshot (fidelity gate). ✓

**Placeholder scan:** No "TBD"/"add error handling" — the AI/reply placeholders are deliberate, specified non-functional surfaces (M5/M7), not plan gaps. ✓

**Type consistency:** `ThreadRow`, `MessageRow`, `SearchHit`, `SplitRule`, `SearchScope`, `LabelOp` are the existing Store types used verbatim. New types (`EmailRowData`, `SplitTab`, `ThreadMessage`, `Command`, `CommandKind`, `LabelRecord`, `AsyncValueObservation<T>`) are each defined in exactly one task and consumed by name in later tasks. `Palette`/`Typography`/`Metrics` defined in Task 2, used everywhere after. `AppModel`/`InboxModel`/`ThreadModel`/`CommandModel`/`SearchModel` signatures are stable across Tasks 4–11. ✓

**Scope check:** One coherent milestone — the visible shell over M1–M4. No send (M5), no scheduling (M6), no AI network (M7). Focused enough for one plan. ✓
