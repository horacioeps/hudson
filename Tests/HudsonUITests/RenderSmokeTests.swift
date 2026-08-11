import AppKit
import GmailKit
import Outbox
import Store
import SwiftUI
import Testing
@testable import HudsonUI

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

    let view = ThreadView(thread: thread, onArchive: {}, onToggleStar: {}, onReply: {})
    let host = NSHostingView(rootView: view)
    host.frame = .init(x: 0, y: 0, width: 760, height: 700)
    host.layout()
    assertRendered(host.fittingSize)
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
