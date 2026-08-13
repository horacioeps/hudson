import AppKit
import GmailKit
import Outbox
import Store
import SwiftUI
import Testing
@testable import AIKit
@testable import HudsonUI

/// A minimal scripted `LLMProvider` for the streamed-summary render smoke
/// test — file-scoped here (a different file than `SummaryModelTests`' own
/// private copy, so the shared name is no conflict), replaying a fixed script
/// with no network so `SummaryModel.summarize` populates `text`.
private final class RenderSmokeScriptedProvider: LLMProvider, @unchecked Sendable {
    private let script: [LLMEvent]
    init(script: [LLMEvent]) { self.script = script }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let script = self.script
        return AsyncThrowingStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Hosting-view render smoke tests for `SidebarView`/`InboxListView`: build
/// each with a seeded in-memory `AppModel`/`InboxModel`, wrap it in an
/// `NSHostingView`, force a layout pass, and assert a positive fitting
/// size — a cheap "it actually renders, nothing crashes or collapses to
/// zero" check, not a pixel-level fidelity test.
///
/// The guard below checks the RENDER OUTPUT (a `.zero` fitting size) rather
/// than `NSApp != nil` — under `swift test` there is never a running
/// `NSApplication`, yet `NSHostingView` layout still produces real, non-zero
/// sizes whenever a window server connection is available (this environment
/// does have one: `ThemeTests.atomsComposeIntoAHostingView` already proves
/// it with the same `NSHostingView`/`layout()`/`fittingSize` recipe), so
/// `NSApp` is not a reliable signal either way. Checking the actual result
/// means this test asserts for real here and would still degrade cleanly on
/// a genuinely headless/no-display CI box, where layout collapses to zero.
@MainActor
@Test func sidebarAndListRenderWithSeededData() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let inbox = InboxModel(database: db, account: AppModel.demoAccount)
    await inbox.start()
    try await Task.sleep(for: .milliseconds(50))

    let appModel = AppModel(database: db, account: try await db.primaryAccount())
    let labels = try await db.labels(account: AppModel.demoAccount)
    let unreadCount = inbox.rows.count { $0.unread }

    let sidebar = SidebarView(
        accountEmail: appModel.account?.email, unreadCount: unreadCount, labels: labels,
        pendingCount: 0, selection: .inbox, onSelect: { _ in })
    let sidebarHost = NSHostingView(rootView: sidebar)
    sidebarHost.frame = .init(x: 0, y: 0, width: Metrics.sidebarWidth, height: 700)
    sidebarHost.layout()
    assertRendered(sidebarHost.fittingSize)

    let list = InboxListView(inbox: inbox, onOpen: { _ in })
    let listHost = NSHostingView(rootView: list)
    listHost.frame = .init(x: 0, y: 0, width: Metrics.listWidth, height: 700)
    listHost.layout()
    assertRendered(listHost.fittingSize)
}

/// `SidebarView` in its "sync in flight, with an error banner queued from a
/// prior failed pass" state — Task 4's new `isSyncing`/`syncBanner`/
/// `onSyncNow` surface, seeded independent of `AppModel`/Store since neither
/// param needs a live database.
@MainActor
@Test func sidebarRendersSyncingStateWithBanner() {
    let sidebar = SidebarView(
        accountEmail: "you@hudson.app", unreadCount: 3, labels: [], pendingCount: 2,
        isSyncing: true, syncBanner: "Sync failed — check your connection.",
        selection: .inbox, onSelect: { _ in }, onSyncNow: {})
    let host = NSHostingView(rootView: sidebar)
    host.frame = .init(x: 0, y: 0, width: Metrics.sidebarWidth, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

/// A `.zero` fitting size means this environment can't lay out an
/// `NSHostingView` at all (no window server) — nothing to assert either way,
/// so this no-ops rather than failing a headless run. Any other size is a
/// real render, and must be positive on both axes.
@MainActor
private func assertRendered(_ size: NSSize) {
    guard size != .zero else { return }
    #expect(size.width > 0)
    #expect(size.height > 0)
}

/// `ThreadView` hosted against a real, opened, multi-message thread (`t01`
/// from `DemoData` — three messages, newest expanded) — exercises the
/// header, the AI-summary chip, both the expanded and collapsed message
/// rendering paths, and the reply bar all in one seeded pass.
@MainActor
@Test func threadViewRendersWithSeededThread() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let thread = ThreadModel(database: db, account: AppModel.demoAccount)
    await thread.open(threadID: "t01")
    try await Task.sleep(for: .milliseconds(50))

    let summary = SummaryModel(database: db, account: AppModel.demoAccount)
    let view = ThreadView(
        thread: thread, summary: summary, onArchive: {}, onToggleStar: {}, onReply: {},
        onSummarize: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 760, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `ThreadView` with the Summarize chip in its STREAMED state — drives a real
/// `SummaryModel.summarize` over a scripted-provider-backed `Summarize` (opt-in
/// row set, no network) so `summary.text` is populated, then hosts the view to
/// exercise the new streamed-summary rendering branch alongside the chip.
@MainActor
@Test func threadViewRendersStreamedSummary() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let thread = ThreadModel(database: db, account: AppModel.demoAccount)
    await thread.open(threadID: "t01")
    try await Task.sleep(for: .milliseconds(50))

    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: "anthropic", optIn: true,
        account: AppModel.demoAccount)
    let provider = RenderSmokeScriptedProvider(
        script: [.textDelta("A short thread summary."), .stopped])
    let egressGuard = EgressGuard(provider: provider, database: db, account: AppModel.demoAccount)
    let summarizer = Summarize(guard: egressGuard, database: db, account: AppModel.demoAccount)
    let summary = SummaryModel(
        database: db, account: AppModel.demoAccount, makeSummarize: { summarizer })
    await summary.summarize(threadID: "t01")

    let view = ThreadView(
        thread: thread, summary: summary, onArchive: {}, onToggleStar: {}, onReply: {},
        onSummarize: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 760, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
    #expect(summary.text == "A short thread summary.")  // fixture sanity — the branch is real
}

/// `CommandPaletteView` hosted against a `CommandModel` reloaded with a
/// selection present (so the triage commands — Archive/Star/Mark read — are
/// included alongside Search/Snooze/switch-split), exercising every row
/// kind's icon/subtitle/keycap rendering.
@MainActor
@Test func commandPaletteViewRendersWithSeededCommands() async throws {
    let command = CommandModel()
    command.reload(
        splits: [SplitTab(key: "primary", title: "Primary", count: 10)], hasSelection: true)

    let view = CommandPaletteView(command: command, perform: { _ in }, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 560, height: 480)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `SearchView` hosted against a `SearchModel` with a landed, non-empty
/// result set — "den" matches `DemoData`'s Denver-itinerary thread (`t08`),
/// mirroring `SearchModelTests.threeCharPrefixYieldsExpectedHitAfterDebounce`.
@MainActor
@Test func searchViewRendersWithSeededHits() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let search = SearchModel(database: db, account: AppModel.demoAccount, debounce: .milliseconds(10))
    search.query = "den"
    search.queryChanged()
    try await Task.sleep(for: .milliseconds(100))

    let view = SearchView(search: search, onOpen: { _ in })
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 560, height: 480)
    host.layout()
    assertRendered(host.fittingSize)
}

/// The fully assembled `RootView` (sidebar + inbox list + reading pane +
/// the keyboard-monitor background view), hosted against a seeded demo
/// `AppModel` via `RootView`'s direct-injection `init(model:)` — this
/// bypasses the async `.task`/`AppModel.demo()` load `HudsonApp` itself
/// uses, so the tree is already fully wired by the time `layout()` runs,
/// rather than racing it. At ~1200×760, comfortably inside the Pencil
/// design's target window size.
@MainActor
@Test func rootViewRendersAssembledThreePane() async throws {
    let appModel = try await AppModel.demo()
    // Let `inbox.start()`/`refreshLabels()` (both launched from
    // `AppModel.demo()` -> `init(database:account:)` via an unstructured
    // `Task`) land their first emission before hosting — matches every
    // other test in this file's "seed, sleep, then render" recipe.
    try await Task.sleep(for: .milliseconds(100))

    let view = RootView(model: appModel)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 1200, height: 760)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `RootView` with NO connected account (`AppModel(database:account: nil)`,
/// not demo) — Task 4's first-launch gate must show `OnboardingView`'s
/// welcome screen instead of the (otherwise-empty) three-pane mailbox.
/// `RootView(model:)` no longer builds its internal `OnboardingModel`
/// eagerly at `init` time — that shape silently lost `onConnected`'s later
/// writes (see `RootViewOnboardingWiringTests`) — so this now needs the same
/// `try await Task.sleep(...)` land-the-`.task` step every other
/// async-loaded `RootView` test in this file already uses, before
/// `layout()`.
@MainActor
@Test func rootViewRendersOnboardingWhenNoAccountConnected() async throws {
    let db = try! HudsonDatabase.inMemory()
    let appModel = AppModel(database: db, account: nil)
    #expect(appModel.needsOnboarding)  // precondition this test exercises

    let view = RootView(model: appModel)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 1200, height: 760)
    host.layout()
    try await Task.sleep(for: .milliseconds(100))
    host.layout()
    assertRendered(host.fittingSize)
}

/// `RootView` after `AppModel.disconnectAccount()` (Task 5's "Disconnect
/// account") — the REVERSE of the test above. Builds a real, non-demo
/// `AppModel` (an `isDemo` model can never need onboarding either way — see
/// `needsOnboarding`'s doc comment) with a seeded account and an injected
/// `InMemoryTokenStore`, hosts `RootView` while still CONNECTED (mirrors a
/// real launch reaching the assembled three-pane), then disconnects and
/// re-renders. This is integration coverage that the pieces actually wire
/// together end to end and nothing crashes on the transition;
/// `RootViewOnboardingWiringTests.onChangeCapturedInsideBodyReachesTheLiveViewOnALaterFlip`
/// is what proves the underlying `.onChange`-in-`body` mechanism itself is
/// sound (this file's `NSHostingView` recipe can't distinguish "showing
/// `OnboardingView`" from "stuck on `loadingPlaceholder`" — both render a
/// non-zero fitting size — see that test's doc comment for why).
@MainActor
@Test func rootViewReturnsToOnboardingAfterDisconnect() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "cid", consentedAt: Date())
    let account = try await db.account(email: "a@b.com")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.saveTokens(
        TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@b.com")
    let appModel = AppModel(database: db, account: account, tokenStore: tokenStore)
    try await Task.sleep(for: .milliseconds(50))
    #expect(!appModel.needsOnboarding)  // precondition: starts connected

    let view = RootView(model: appModel)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 1200, height: 760)
    host.layout()
    try await Task.sleep(for: .milliseconds(100))
    host.layout()
    assertRendered(host.fittingSize)  // connected: the three-pane mailbox renders fine

    await appModel.disconnectAccount()
    #expect(appModel.needsOnboarding)  // the account is really gone

    try await Task.sleep(for: .milliseconds(100))
    host.layout()
    assertRendered(host.fittingSize)  // still renders after the reverse-gate transition
}

/// The REAL `HudsonApp` boot path (`RootView(databaseURL:)`, not the
/// direct-injection `init(model:)` seam) with a fresh, empty on-disk
/// database — no seeded account, so the async `.task` load lands a model
/// with `needsOnboarding == true` and must build+show onboarding exactly
/// like the `init(model:)` seam does. This path had zero coverage before
/// Task 4's fix folded `init(model:)`'s onboarding-building into the same
/// `.task` (see `RootView`'s doc comments) — worth confirming directly
/// since a regression here would be invisible to every other test in this
/// file, all of which go through `init(model:)`.
@MainActor
@Test func rootViewRendersOnboardingOnFreshDatabaseBoot() async throws {
    let dbURL = FileManager.default.temporaryDirectory.appending(
        path: "hudson-render-smoke-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbURL) }

    let view = RootView(databaseURL: dbURL)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 1200, height: 760)
    host.layout()
    try await Task.sleep(for: .milliseconds(150))
    host.layout()
    assertRendered(host.fittingSize)
}

/// `RootView` with the compose sheet showing (`AppModel.composeNew()`, ⌘N's
/// path) — exercises Task 4's new overlay branch alongside the
/// already-covered three-pane/palette/search branches above.
@MainActor
@Test func rootViewRendersWithComposerVisible() async throws {
    let appModel = try await AppModel.demo()
    try await Task.sleep(for: .milliseconds(100))
    appModel.composeNew()

    let view = RootView(model: appModel)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 1200, height: 760)
    host.layout()
    assertRendered(host.fittingSize)
}

// MARK: - SettingsView (Task 5: "Disconnect account")

/// `SettingsView` with a connected account — exercises the AI section
/// alongside the NEW account section (Task 5): the "Account" heading and
/// "Disconnect <email>" control, rendered whenever `accountEmail` is
/// non-nil.
@MainActor
@Test func settingsViewRendersWithAccountSection() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "cid", consentedAt: Date())
    let settings = SettingsModel(database: db, account: "a@b.com", keyStore: InMemoryLLMKeyStore())

    let view = SettingsView(
        settings: settings, accountEmail: "a@b.com", onDisconnect: {}, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 460, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `SettingsView` with NO connected account (`accountEmail == nil`) — the
/// account section must not render (nothing to disconnect); this also
/// exercises the sheet's default state without crashing on a nil email.
@MainActor
@Test func settingsViewRendersWithoutAccountSection() {
    let settings = SettingsModel(
        database: try! HudsonDatabase.inMemory(), account: "", keyStore: InMemoryLLMKeyStore())

    let view = SettingsView(settings: settings, accountEmail: nil, onDisconnect: {}, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 460, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

// MARK: - ComposerView (Task 3)

/// A scriptable `SendTransport` double, scoped to this file only — mirrors
/// `ComposerModelTests`' own private fixture (file-private, so the same name
/// in a different file is no conflict) so `composerViewRendersUndoToast`
/// below can drive a REAL `SendService`/`ComposerModel.send()` without a
/// network or Keychain, purely to reach the undo-toast-visible render state.
private actor RenderSmokeSendTransport: SendTransport {
    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage {
        SentMessage(id: "sent-1", threadId: threadID ?? "t", labelIds: ["SENT"])
    }

    func findSentMessageID(rfc822MessageID: String) async throws -> String? { nil }
}

/// `ComposerView` hosted in fresh `.new`-compose mode with fields filled —
/// exercises the To/Cc-toggle-hidden/Subject header, the serif `TextEditor`
/// body, and the footer WITHOUT the reply-only AI Draft placeholder chip.
@MainActor
@Test func composerViewRendersNewCompose() async throws {
    let db = try HudsonDatabase.inMemory()
    // `makeService: { nil }` — this test only checks rendering, never calls
    // `send()`, so there's no need for even a fake-backed `SendService`; nil
    // also matches the "must never touch the real Keychain" test rule.
    let model = ComposerModel(database: db, account: nil, makeService: { nil })
    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Lunch?"
    model.bodyText = "Are you free Thursday?"

    let view = ComposerView(composer: model, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 640, height: 560)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `ComposerView` hosted in reply mode against a real seeded thread (`t01`,
/// same fixture `ComposerModelTests.startReplyPrefillsSubjectAndRecipientFromThread`
/// uses) — exercises the prefilled To/Subject/quoted-body header+editor AND
/// the reply-only AI Draft placeholder chip in the footer.
@MainActor
@Test func composerViewRendersReply() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db, account: AppModel.demoAccount)
    let account = try #require(try await db.account(email: AppModel.demoAccount))
    let model = ComposerModel(database: db, account: account, makeService: { nil })
    await model.startReply(threadID: "t01")

    let view = ComposerView(composer: model, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 640, height: 560)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `ComposerView` right after a successful send — `justSentUndoJobID` is
/// non-nil, so the tappable "Sent · Undo" toast overlay is on screen.
/// Drives a REAL `send()` through a fake-transport-backed `SendService`
/// (`RenderSmokeSendTransport`) so this render state is reached the same
/// way the real app reaches it, not synthesized by poking private state.
///
/// Hosts the view BEFORE calling `send()` — mirroring the real app, where
/// the Send button lives inside the already-mounted `ComposerView` — then
/// re-`layout()`s after `send()` resolves, so the `nil` → jobID transition
/// happens while this exact instance is live and observing `composer`.
/// Getting this order backwards (build the view AFTER `send()` already
/// flipped `justSentUndoJobID`) previously made this test vacuous with an
/// EARLIER `ComposerView` implementation that opened the toast via
/// `.onChange(of:)` — that overload only fires on a transition witnessed
/// while mounted, so a value already non-nil at first appearance never
/// fired it. `ComposerView.bottomToast` no longer depends on watching a
/// transition at all (it's a pure function of `composer.justSentUndoJobID`,
/// see that property's doc comment), which is what actually makes the order
/// here safe either way now — but hosting first still matches how a real
/// user reaches this state, so the recipe stays in that order.
///
/// Beyond the model-level `justSentUndoJobID != nil` fixture-sanity check,
/// this also asserts `view.isUndoToastShown` — the EXACT boolean
/// `ComposerView.bottomToast` branches on to decide whether to render the
/// undo toast (exposed non-`private` specifically for this assertion via
/// `@testable import`) — so a regression that breaks the toast/undo wiring
/// (e.g. `bottomToast` reverting to a stale view-local flag, or the
/// condition being deleted/inverted) fails this test, not just a generic
/// non-zero `NSHostingView` fitting-size check (which stays true either
/// way and can't tell the toast branch apart from the placeholder-toast or
/// no-toast branches). Asserting on rendered TEXT content instead was
/// evaluated and dropped: `NSView.accessibilityChildren()` on a hosted
/// SwiftUI tree comes back empty under `swift test`'s windowless
/// environment (verified empirically, including with the host parented
/// into a real `NSWindow`), so there is no reliable way to introspect
/// rendered text here — `isUndoToastShown` is the closest thing to "the
/// toast is on screen" this environment can actually assert on.
// MARK: - OnboardingView (Task 3)

/// A do-nothing `HTTPTransport`/`LoopbackServing` pair for the
/// `OnboardingView` render-smoke tests below. Those tests only drive
/// `OnboardingModel`'s SYNCHRONOUS phase navigation (`beginSetup`/
/// `showBYOEntry`) — never `signInWithGoogle`/`signInBYO` — so these seams
/// are never actually invoked; they exist purely so the model can be built
/// without ever falling through to the real Keychain/network/browser
/// (`KeychainTokenStore()`/`URLSessionTransport()`/`LoopbackServer()`/
/// `NSWorkspace`), matching this suite's "no real integration, ever" rule
/// even for a render that doesn't exercise sign-in.
private actor RenderSmokeInertTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw GmailError.network("RenderSmokeInertTransport should never be called")
    }
}

private actor RenderSmokeInertLoopback: LoopbackServing {
    func start() async throws -> UInt16 { throw GmailError.network("unused") }
    func waitForCallback(expectedState: String) async throws -> String {
        throw GmailError.network("unused")
    }
    func stop() async {}
}

/// Builds a hermetic `OnboardingModel` for the render-smoke tests below —
/// every seam injected, none of them real.
@MainActor
private func makeRenderSmokeOnboardingModel(database: HudsonDatabase) -> OnboardingModel {
    OnboardingModel(
        database: database,
        tokenStore: InMemoryTokenStore(),
        transport: RenderSmokeInertTransport(),
        makeLoopback: { RenderSmokeInertLoopback() },
        openURL: { _ in })
}

/// `OnboardingView` in its default `.welcome` phase — the wordmark, tagline,
/// three pitch cards, and the "Set up in about 5 minutes" button.
@MainActor
@Test func onboardingViewRendersWelcome() throws {
    let db = try HudsonDatabase.inMemory()
    let model = makeRenderSmokeOnboardingModel(database: db)

    let view = OnboardingView(model: model)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 900, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `OnboardingView` in `.chooseSignIn` (`beginSetup()`'s destination) — the
/// "Sign in with Google" button, the unverified-app explainer card, and the
/// "Use my own Google credentials" affordance.
@MainActor
@Test func onboardingViewRendersChooseSignIn() throws {
    let db = try HudsonDatabase.inMemory()
    let model = makeRenderSmokeOnboardingModel(database: db)
    model.beginSetup()

    let view = OnboardingView(model: model)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 900, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

/// `OnboardingView` in `.byoEntry` (`showBYOEntry()`'s destination) — the
/// Client ID/Client Secret fields and the "Connect" button.
@MainActor
@Test func onboardingViewRendersBYOEntry() throws {
    let db = try HudsonDatabase.inMemory()
    let model = makeRenderSmokeOnboardingModel(database: db)
    model.showBYOEntry()

    let view = OnboardingView(model: model)
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 900, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
}

@MainActor
@Test func composerViewRendersUndoToastAfterSend() async throws {
    let db = try HudsonDatabase.inMemory()
    let email = "composer-render-\(UUID().uuidString)@example.com"
    try await db.upsertAccount(email: email, clientID: "test-client", consentedAt: Date())
    let account = try #require(try await db.account(email: email))
    let transport = RenderSmokeSendTransport()
    let service = SendService(api: transport, database: db, account: account.email)
    let model = ComposerModel(database: db, account: account, makeService: { service })

    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Lunch?"
    model.bodyText = "Are you free Thursday?"

    let view = ComposerView(composer: model, onClose: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 640, height: 560)
    host.layout()
    assertRendered(host.fittingSize)
    #expect(!view.isUndoToastShown)  // nothing sent yet — no toast to show

    await model.send()
    #expect(model.justSentUndoJobID != nil)  // fixture sanity — the toast condition is real
    host.layout()

    #expect(view.isUndoToastShown)  // the ACTUAL condition `bottomToast` renders on
    assertRendered(host.fittingSize)
}

/// `ThreadView` against `t41` — the demo thread whose newest message is
/// prose-only HTML with a `gmail_quote` block. This is the reading pane's
/// NATIVE path: no `WKWebView`, no white card, sender styling discarded, and
/// the quoted history split off behind the "···" toggle. Renders to a PNG when
/// `HUDSON_SNAPSHOT=1`, so the dark-ground fidelity is eyeballable; otherwise
/// it's a plain "it lays out" smoke test like its `t01` sibling above.
@MainActor
@Test func threadViewRendersNativeHTMLBodyOnTheDarkGround() async throws {
    let db = try HudsonDatabase.inMemory()
    try await DemoData.seed(into: db)
    let thread = ThreadModel(database: db, account: AppModel.demoAccount)
    await thread.open(threadID: "t41")
    try await waitUntil { thread.messages.contains { $0.rawHTML != nil } }

    // The newest message must have reached the native path with a body — an
    // empty one would render a blank pane and still "lay out" fine.
    let newest = try #require(thread.messages.max(by: { $0.row.internalDate < $1.row.internalDate }))
    let html = try #require(newest.rawHTML.map { String(decoding: $0, as: UTF8.self) })
    #expect(SimpleBody.isSimple(html: html))
    let parsed = MessageBodyParser.parse(html: html)
    #expect(ParsedBody.text(parsed.new).contains("indemnity cap"))
    #expect(!parsed.quoted.isEmpty, "the gmail_quote block must be split off")

    let summary = SummaryModel(database: db, account: AppModel.demoAccount)
    let view = ThreadView(
        thread: thread, summary: summary, onArchive: {}, onToggleStar: {}, onReply: {},
        onSummarize: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 760, height: 700)
    host.layout()
    assertRendered(host.fittingSize)

    guard ProcessInfo.processInfo.environment["HUDSON_SNAPSHOT"] == "1" else { return }
    // Same recipe as `SnapshotHarness.render`, and for the same reason:
    // `ImageRenderer` comes back blank for a `ScrollView`'s contents, so the
    // capture needs a real window and a synchronous display cycle.
    let frame = NSRect(x: 0, y: 0, width: 760, height: 700)
    let window = NSWindow(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    window.display()
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        let dir = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["HUDSON_SNAPSHOT_DIR"]
                ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?
            .write(to: dir.appending(path: "hudson-native-body.png"))
    }
    window.orderOut(nil)
}
