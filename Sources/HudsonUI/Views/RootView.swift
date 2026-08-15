import Store
import SwiftUI

/// Root scene content: the assembled three-pane mailbox (sidebar / inbox
/// list / reading pane), the ⌘K palette and search overlays, the global
/// keyboard monitor, and a top-pinned sync banner. Owns exactly one
/// `AppModel` per launch — every child view below binds directly to that
/// model's `inbox`/`thread`/`command`/`search`, matching each view's own
/// "no Store calls of its own" contract (see their doc comments).
public struct RootView: View {
    @State private var model: AppModel?
    /// The first-launch onboarding flow (Task 4's gate) — built by the
    /// `.task` below, the ONE call site for both boot paths, the instant
    /// `model` lands with `needsOnboarding == true` (whether `model` was
    /// seeded eagerly via `init(model:)` or loaded async from
    /// `databaseURL`). `nil` whenever onboarding isn't (yet, or no longer)
    /// showing, including the entire lifetime of a returning user's launch.
    @State private var onboarding: OnboardingModel?
    /// `nil` when constructed via `init(model:)` — the direct-injection
    /// seam for tests/previews, which skips the async model-load half of
    /// the `.task` below (guarded on `databaseURL`) because `model` already
    /// has a value; the onboarding-building half still runs for it.
    private let databaseURL: URL?
    private let isDemo: Bool

    /// The real entry point — `HudsonApp` uses this. `isDemo` routes
    /// through `AppModel.demo()` (a fixed-path temp database, seeded with
    /// `DemoData` on first open) instead of opening `databaseURL` — used by
    /// `--demo`/`HUDSON_DEMO=1` for screenshots and manual QA without ever
    /// touching a real mailbox.
    public init(databaseURL: URL, isDemo: Bool = false) {
        self.databaseURL = databaseURL
        self.isDemo = isDemo
    }

    /// Direct-injection initializer for tests and previews (an already-
    /// built `AppModel`, e.g. from `AppModel.demo()`) — mirrors
    /// `AppModel`'s own `init(database:account:)` test seam, and lets a
    /// render-smoke test host the fully assembled tree against real,
    /// already-loaded data instead of racing the async `.task` below.
    ///
    /// Deliberately does NOT build `onboarding` here — see the `.task`
    /// below, which builds it for both this seam's already-`needsOnboarding`
    /// model AND the real `databaseURL` boot path's freshly-loaded one. Only
    /// `model` is seeded eagerly; it carries no escaping closures, so there
    /// is nothing about seeding it here that a pre-install `self` capture
    /// could ever lose.
    public init(model: AppModel) {
        self.databaseURL = nil
        self.isDemo = false
        self._model = State(initialValue: model)
        self._onboarding = State(initialValue: nil)
    }

    public var body: some View {
        // Switched on `bootPhase` rather than re-testing `model`/`onboarding`
        // here. An earlier version duplicated the conditions inline, and when
        // `bootPhase`'s precedence changed the inline copy silently kept the
        // old order — `bootPhase` is consumed only by `.animation(value:)`
        // below, so nothing failed loudly and the AI-key step simply never
        // mounted. One expression decides, and the animation keys off the same
        // value it renders from.
        Group {
            switch bootPhase {
            case .mailbox:
                // `bootPhase` returns `.mailbox` only when `model` is non-nil
                // and past onboarding, but the optional is re-unwrapped here
                // rather than force-unwrapped — a future edit to `bootPhase`
                // must not be able to turn a precedence change into a crash.
                if let model, !model.needsOnboarding {
                    assembled(model)
                        .transition(.opacity)
                }
            case .onboarding:
                // First launch, no account yet (Task 4's gate) — the ENTIRE
                // mailbox chrome stays unmounted until a real account exists,
                // matching `HudsonCLI`'s old "no account -> can't do
                // anything" posture, just with a graphical sign-in instead of
                // a terminal command.
                //
                // This branch also covers the window where BOTH are live: the
                // account row exists and its mail is already downloading,
                // while the optional AI-key step is still on screen.
                if let onboarding {
                    OnboardingView(model: onboarding)
                        .transition(.opacity)
                }
            case .loading:
                loadingPlaceholder
                    .transition(.opacity)
            }
        }
        // Opacity only, and only between these three branches. Both crossings
        // are once-per-launch arrivals into a shell the user is waiting on
        // (boot, and finishing sign-in), which is the one case where an
        // async-driven transition is honest rather than jank. Nothing here may
        // animate size: the `.frame` below sits outside this `Group` precisely
        // so the window's minimums are never interpolated, and
        // `RenderSmokeTests` measures `fittingSize` immediately after the
        // onboarding branch flips.
        .animation(Motion.crossfade, value: bootPhase)
        .frame(minWidth: 1040, minHeight: 680)
        .background(Palette.bgApp)
        .task {
            // Builds `onboarding` for BOTH boot paths, from the ONE call
            // site — and only from here, never from `init` — so
            // `makeOnboardingModel`'s escaping `onConnected` closure always
            // captures `self` AFTER SwiftUI has run `body` at least once
            // for this view's identity. `.task` is guaranteed to run after
            // that first `body` pass, which is exactly what makes capturing
            // `self` inside it safe (see `makeOnboardingModel`'s doc
            // comment). Covers `init(model:)`'s already-loaded, already-
            // `needsOnboarding` model (the `model == nil` guard below would
            // otherwise skip it entirely) as well as the real `databaseURL`
            // boot path's freshly-loaded one.
            if let model, model.needsOnboarding, onboarding == nil {
                onboarding = makeOnboardingModel(for: model)
            }

            guard model == nil, let databaseURL else { return }
            let loaded = try? await (isDemo ? AppModel.demo() : AppModel(databaseURL: databaseURL))
            model = loaded
            guard let loaded else { return }
            if loaded.needsOnboarding {
                onboarding = makeOnboardingModel(for: loaded)
            } else {
                // Keep the mailbox live automatically — a no-op without
                // creds (e.g. `--demo`), so it costs nothing there.
                loaded.startAutoSync()
            }
        }
        // The REVERSE of the `.task` gate above (Task 5: "Disconnect
        // account"). `.task` only ever runs ONCE per view identity — it
        // can't itself react to `needsOnboarding` flipping `true` sometime
        // LATER, which is exactly what `SettingsView`'s "Disconnect" does
        // via `AppModel.disconnectAccount()` clearing `account`. This
        // modifier is what makes that later flip re-show `OnboardingView`.
        //
        // Built here — inside a body-attached modifier, evaluated only
        // after SwiftUI installs this view's `@State` — for the identical
        // reason `.task` is (see `makeOnboardingModel`'s doc comment): a
        // closure capturing `self` is only safe once `body` has run at
        // least once for this identity. `RootViewOnboardingWiringTests`
        // reproduces this exact shape (`.onChange` instead of `.task`) in
        // isolation and confirms the write reaches the live tree.
        //
        // Guards match `.task`'s own: only fires on an ACTUAL transition to
        // `true` (SwiftUI's `onChange` never fires for a view's first
        // render, so this never races the forward gate's initial build —
        // see `onChange`'s call site doc below) and only builds when
        // `onboarding` isn't already showing, so a stray double-fire is a
        // harmless no-op rather than a second `OnboardingModel` clobbering
        // the first.
        .onChange(of: model?.needsOnboarding) { _, needsOnboarding in
            guard needsOnboarding == true, let model, onboarding == nil else { return }
            onboarding = makeOnboardingModel(for: model)
        }
    }

    /// Which of `body`'s three branches is showing, as one value to key the
    /// crossfade on. Deliberately NOT the `model` identity: swapping in a new
    /// `AppModel` for the same phase (there is no such path today, but there
    /// is nothing stopping one) must not re-fade an already-visible mailbox.
    enum BootPhase { case loading, onboarding, mailbox }

    private var bootPhase: BootPhase {
        Self.resolveBootPhase(
            hasOnboarding: onboarding != nil,
            hasReadyMailbox: model.map { !$0.needsOnboarding } ?? false)
    }

    /// Which branch `body` renders, as a pure function of the two inputs.
    ///
    /// Extracted so the precedence rule is unit-testable: `@State` can't be
    /// read back off a `View` value a test constructs (see
    /// `RootViewOnboardingWiringTests` for the empirical write-up), so a rule
    /// left inline here is a rule nothing can assert on — which is exactly how
    /// this went wrong once already. `body` and the crossfade both read the
    /// same value, so they cannot disagree.
    ///
    /// **Onboarding outranks a ready mailbox.** Between `onAccountPersisted`
    /// and `onConnected` BOTH are live at once — the account exists and its
    /// mail is already downloading, while the optional AI-key step is still on
    /// screen. Getting this backwards unmounts that step the instant the
    /// account row lands, which strands `onboarding` non-nil forever (its only
    /// exit is a button on the unmounted screen) and leaves a stale model that
    /// resurfaces after a disconnect.
    static func resolveBootPhase(hasOnboarding: Bool, hasReadyMailbox: Bool) -> BootPhase {
        if hasOnboarding { return .onboarding }
        if hasReadyMailbox { return .mailbox }
        return .loading
    }

    // MARK: - Onboarding (Task 4's gate — see `onboarding` above)

    /// Builds a fresh `OnboardingModel` over `model`'s already-open
    /// `database` (no second `HudsonDatabase.open` for the same file — this
    /// reuses the live connection) and wires `onConnected` to swap `self`
    /// over to the mailbox: a BRAND NEW `AppModel` built for the just-signed-
    /// in account (never mutated in place — every child model, `inbox`
    /// through `composer`, is scoped to an account's email at construction),
    /// followed by `startAutoSync()` and clearing `onboarding` so the body's
    /// `assembled(model)` branch takes over. Called ONLY from the `.task`
    /// above — for both `init(model:)`'s already-`needsOnboarding` model and
    /// the `databaseURL` boot path's freshly-loaded one — a single call site
    /// so the wiring can never drift between the two AND so `onConnected`'s
    /// capture of `self` (below) is always safe.
    ///
    /// Capturing `self` in `onConnected` (an escaping closure held by a
    /// long-lived `OnboardingModel`) is safe here despite `RootView` being a
    /// value type: `@State`'s `wrappedValue` setter is `nonmutating`, so
    /// writing `self.model`/`self.onboarding` from a closure captured by an
    /// older copy of `self` writes through to the SAME shared storage
    /// SwiftUI keeps for this view's identity — but ONLY once that storage
    /// has actually been installed, which happens the first time SwiftUI
    /// runs `body` for this identity. `.task` is guaranteed to run after
    /// that first `body` pass, so `self` here is always a body-bound copy.
    /// Building this same closure directly inside a custom `init` (as an
    /// earlier version of this method did for the `init(model:)` seam) is
    /// NOT safe: `self` there is whatever the caller constructed by hand,
    /// never derived from SwiftUI's own state-graph installation, so a
    /// later write through it lands on a disconnected, pre-install copy of
    /// `@State` that the live-rendered tree never sees again — confirmed
    /// empirically in `RootViewOnboardingWiringTests`, which reproduces this
    /// exact capture shape in isolation.
    private func makeOnboardingModel(for model: AppModel) -> OnboardingModel {
        let database = model.database
        let onboardingModel = OnboardingModel(database: database)
        // Split in two so the AI-key step costs the user no mail-download
        // time. `onAccountPersisted` fires the moment the account row exists:
        // it builds the mailbox and starts syncing immediately, but leaves
        // `onboarding` set, so `bootPhase` keeps the key step on screen while
        // backfill runs behind it. `onConnected` then fires when that step
        // resolves and simply dismisses onboarding — the mailbox it reveals is
        // already partly full.
        onboardingModel.onAccountPersisted = { [self] record in
            let mailbox = AppModel(database: database, account: record)
            self.model = mailbox
            mailbox.startAutoSync()
        }
        onboardingModel.onConnected = { [self] record in
            // Defensive: a host that reached `onConnected` without the
            // persisted hook having built a mailbox (an older wiring, or a
            // test) still gets one rather than a blank window.
            if self.model == nil || self.model?.needsOnboarding == true {
                let mailbox = AppModel(database: database, account: record)
                self.model = mailbox
                mailbox.startAutoSync()
            }
            self.onboarding = nil
        }
        return onboardingModel
    }

    private var loadingPlaceholder: some View {
        ZStack {
            Palette.bgApp.ignoresSafeArea()
            Text("Hudson")
                .font(Typography.serif(40, .semibold))
                .foregroundStyle(Palette.ink)
        }
    }

    // MARK: - Assembled three-pane + overlays

    @ViewBuilder
    private func assembled(_ model: AppModel) -> some View {
        ZStack {
            threePane(model)

            syncBannerStrip(model)
            overlays(model)
            sentUndoToast(model)
        }
        // Invisible — installs the app-wide `NSEvent` monitor that drives
        // every keyboard shortcut (see `KeyboardMonitor`/`KeyRouter`).
        .background(KeyboardMonitor(appModel: model))
    }

    /// The top-pinned sync banner. Safe to slide — it OVERLAYS the panes
    /// rather than displacing them (that `Spacer` is what keeps it out of the
    /// layout), so an inbox row's frame can never move because a banner
    /// arrived, and the list's 16ms budget is untouched.
    private func syncBannerStrip(_ model: AppModel) -> some View {
        VStack(spacing: 0) {
            if let syncBanner = model.syncBanner {
                Banner(text: syncBanner, role: .warn)
                    .transition(Motion.banner)
            }
            Spacer(minLength: 0)
        }
        .animation(model.syncBanner == nil ? Motion.dismiss : Motion.settle, value: model.syncBanner)
    }

    /// The modal stack. All four overlays share ONE animation, keyed on all
    /// four flags at once, for two reasons: the palette→search handoff closes
    /// one and opens the other in the same tick (`AppModel.showSearch`), so a
    /// single transaction cross-fades them instead of flashing the scrim off
    /// and back on; and the direction is read off the resulting state, which
    /// is what buys the asymmetry — arriving should feel placed (`present`'s
    /// spring), dismissing should feel instant (`dismiss`'s half-length ease).
    private func overlays(_ model: AppModel) -> some View {
        let visible = OverlayVisibility(model)
        return ZStack {
            overlay(isPresented: model.isPaletteVisible) {
                CommandPaletteView(
                    command: model.command,
                    perform: { model.perform($0) },
                    onClose: { model.isPaletteVisible = false })
            } onDismiss: {
                model.isPaletteVisible = false
            }

            overlay(isPresented: model.isSearchVisible) {
                SearchView(
                    search: model.search,
                    onOpen: { threadID in
                        model.isSearchVisible = false
                        model.openThread(threadID)
                    })
            } onDismiss: {
                model.isSearchVisible = false
            }

            overlay(isPresented: model.isComposerVisible) {
                ComposerView(
                    composer: model.composer, onClose: { model.isComposerVisible = false })
            } onDismiss: {
                model.isComposerVisible = false
            }

            overlay(isPresented: model.isSettingsVisible) {
                SettingsView(
                    settings: model.settings,
                    accountEmail: model.account?.email,
                    onDisconnect: { Task { await model.disconnectAccount() } },
                    onClose: { model.isSettingsVisible = false })
            } onDismiss: {
                model.isSettingsVisible = false
            }
        }
        .animation(visible.isEmpty ? Motion.dismiss : Motion.present, value: visible)
    }

    /// The four overlay flags as one comparable value — every flip animates,
    /// and `isEmpty` is what tells the modifier above whether this frame is an
    /// arrival or a dismissal.
    private struct OverlayVisibility: Equatable {
        let palette: Bool, search: Bool, composer: Bool, settings: Bool

        @MainActor init(_ model: AppModel) {
            palette = model.isPaletteVisible
            search = model.isSearchVisible
            composer = model.isComposerVisible
            settings = model.isSettingsVisible
        }

        var isEmpty: Bool { !(palette || search || composer || settings) }
    }

    private func threePane(_ model: AppModel) -> some View {
        // A real AppKit `NSSplitView` (via `HSplitView`), NOT
        // `NavigationSplitView`: the latter gives no freely-draggable divider
        // between the list and the reading pane on macOS and lets the detail
        // column greedily eat the remaining width. `HSplitView`'s dividers drag
        // freely within each pane's frame bounds, so the reading pane is
        // genuinely resizable — drag the divider to its left to size it.
        HSplitView {
            SidebarView(
                accountEmail: model.account?.email,
                unreadCount: model.totalUnread,
                labels: model.labels,
                pendingCount: model.pendingCount,
                isSyncing: model.isSyncing,
                isCatchingUp: model.isCatchingUp,
                isSyncStalled: model.isSyncStalled,
                backfillFraction: model.backfillFraction,
                backfillProgress: model.backfillProgress,
                syncBanner: model.syncBanner,
                selection: model.sidebarSelection,
                onSelect: { model.selectFolder($0) },
                onSyncNow: { Task { await model.syncNow() } },
                onSettings: { model.isSettingsVisible = true },
                onCompose: { model.composeNew() })
                .frame(minWidth: 200, idealWidth: Metrics.sidebarWidth, maxWidth: 300)

            InboxListView(
                inbox: model.inbox,
                isCatchingUp: model.isCatchingUp,
                onOpen: { model.openThread($0) })
                .frame(minWidth: 300, idealWidth: Metrics.listWidth, maxWidth: 620)

            // Reading pane: takes the remaining width, freely resizable via the
            // divider on its left. Only mount the full ThreadView once a thread
            // is open; otherwise a bare centered empty state, so the pane never
            // shows dead chrome (a Reply bar with nothing to reply to).
            Group {
                if model.inbox.selectedThreadID != nil && !model.thread.messages.isEmpty {
                    ThreadView(
                        thread: model.thread,
                        summary: model.summary,
                        onArchive: { Task { try? await model.inbox.archiveSelected() } },
                        onToggleStar: { Task { try? await model.inbox.toggleStarSelected() } },
                        onReply: { model.replyToOpenThread() },
                        onSummarize: { model.summarizeOpenThread() })
                } else {
                    readingPaneEmptyState
                        .transition(.opacity)
                }
            }
            // Keyed on the CLICK, never on `thread.messages` — which is the
            // deliberate reason only the CLOSING direction fades here. The
            // second half of the condition above lands asynchronously
            // (`thread.open` is a `Task`), so a key that included it would
            // fire once on the click and again when the rows arrive, playing
            // the fade twice with the second pass starting half-faded. Mail
            // appearing because a fetch returned is not a state change the
            // user made, and it stays a hard cut. Content only either way —
            // both branches already sit on `bgSurface`, so the backdrop never
            // moves.
            .animation(Motion.crossfade, value: model.inbox.selectedThreadID)
            .frame(minWidth: 420, maxWidth: .infinity)
        }
        .background(Palette.bgApp)
    }

    /// Shown in the detail pane when no thread is open — a subtle, centered
    /// prompt on the reading pane's own surface, with none of `ThreadView`'s
    /// chrome. Sits on `Palette.bgSurface` (the reading pane's background) so
    /// switching to a real thread doesn't shift the backdrop.
    private var readingPaneEmptyState: some View {
        VStack(spacing: Metrics.unit * 3) {
            Image(systemName: "envelope")
                .font(Typography.ui(34))
                .foregroundStyle(Palette.inkTertiary)
            Text("Select a conversation")
                .font(Typography.ui(15))
                .foregroundStyle(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgSurface)
    }

    /// The "Sent · Undo" toast, rendered at THIS level rather than inside
    /// `ComposerView` itself — resolves `ComposerView`'s own "open question
    /// for Task 4" doc comment. `ComposerModel.send()` fires `onClose?()`
    /// synchronously right after enqueueing, which `AppModel` wires to
    /// `isComposerVisible = false` (`wireComposerDismissal`) — so the sheet
    /// is already gone by the time this toast needs to show. Keying this
    /// off `composer.justSentUndoJobID` directly (the same pure condition
    /// `ComposerView.isUndoToastShown` uses) means the undo affordance
    /// survives the sheet's dismissal instead of disappearing with it: the
    /// job is still durably held in `send_jobs` for the rest of its undo
    /// window regardless of whether any view is showing it, and this is
    /// what keeps that real window visibly actionable.
    ///
    /// It rises in and fades out WITHOUT moving: the removal is usually the
    /// 15s window expiring on its own, and sliding away would claim the user
    /// dismissed it. `Motion.toast` encodes exactly that asymmetry.
    private func sentUndoToast(_ model: AppModel) -> some View {
        VStack {
            Spacer(minLength: 0)
            if model.composer.justSentUndoJobID != nil {
                Button(action: { Task { await model.composer.undo() } }) {
                    Toast(text: "Sent · Undo")
                }
                .buttonStyle(.pressable)
                .padding(.bottom, Metrics.unit * 8)
                .transition(Motion.toast)
            }
        }
        .animation(
            model.composer.justSentUndoJobID == nil ? Motion.dismiss : Motion.present,
            value: model.composer.justSentUndoJobID)
    }

    /// A dimmed, click-to-dismiss backdrop behind a centered modal —
    /// shared shape for the palette and search overlays. Matches both
    /// views' own `.shadow(color: .black.opacity(0.4), radius: 24, y: 12)`
    /// styling of the modal itself; this is the scrim BEHIND it.
    ///
    /// Owns its own `isPresented` gate so the scrim and the card can carry
    /// different transitions — the scrim is a flat cross-fade and gets there
    /// ahead of the card, which scales in under the shared spring. Never a
    /// blur or a material on that backdrop: it covers the full window, and a
    /// per-frame composite of the entire mailbox costs far more than the
    /// polish is worth.
    @ViewBuilder
    private func overlay<Content: View>(
        isPresented: Bool, @ViewBuilder content: () -> Content,
        onDismiss: @escaping () -> Void
    ) -> some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                    .transition(.opacity.animation(Motion.crossfade))
                content()
                    .transition(Motion.overlayCard)
            }
        }
    }
}
