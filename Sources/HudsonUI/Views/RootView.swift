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
    /// The first-launch onboarding flow (Task 4's gate) — built the instant
    /// `model` lands with `needsOnboarding == true`, either eagerly in
    /// `init(model:)` or inside the `.task` below for the real `databaseURL`
    /// boot path. `nil` whenever onboarding isn't (yet, or no longer)
    /// showing, including the entire lifetime of a returning user's launch.
    @State private var onboarding: OnboardingModel?
    /// `nil` when constructed via `init(model:)` — the direct-injection
    /// seam for tests/previews, which skips the async `.task` load below
    /// entirely because `model` already has a value.
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
    /// Builds `onboarding` EAGERLY, right here, whenever `model` already
    /// `needsOnboarding` — unlike the `.task`-driven boot path, this
    /// initializer never runs the async load, so there is no later moment to
    /// build it in; doing it now (rather than lazily on first `body`
    /// evaluation) also sidesteps ever mutating `@State` from inside `body`,
    /// which SwiftUI disallows.
    public init(model: AppModel) {
        self.databaseURL = nil
        self.isDemo = false
        self._model = State(initialValue: model)
        self._onboarding = State(initialValue: nil)
        if model.needsOnboarding {
            self.onboarding = makeOnboardingModel(for: model)
        }
    }

    public var body: some View {
        Group {
            if let model, !model.needsOnboarding {
                assembled(model)
            } else if let onboarding {
                // First launch, no account yet (Task 4's gate) — the ENTIRE
                // mailbox chrome stays unmounted until a real account exists,
                // matching `HudsonCLI`'s old "no account -> can't do
                // anything" posture, just with a graphical sign-in instead of
                // a terminal command.
                OnboardingView(model: onboarding)
            } else {
                loadingPlaceholder
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Palette.bgApp)
        .task {
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
    }

    // MARK: - Onboarding (Task 4's gate — see `onboarding` above)

    /// Builds a fresh `OnboardingModel` over `model`'s already-open
    /// `database` (no second `HudsonDatabase.open` for the same file — this
    /// reuses the live connection) and wires `onConnected` to swap `self`
    /// over to the mailbox: a BRAND NEW `AppModel` built for the just-signed-
    /// in account (never mutated in place — every child model, `inbox`
    /// through `composer`, is scoped to an account's email at construction),
    /// followed by `startAutoSync()` and clearing `onboarding` so the body's
    /// `assembled(model)` branch takes over. Called from both `init(model:)`
    /// (direct-injection callers whose model already `needsOnboarding`) and
    /// the `.task` boot path — a single definition so the wiring can never
    /// drift between the two.
    ///
    /// Capturing `self` in `onConnected` (an escaping closure held by a
    /// long-lived `OnboardingModel`) is safe here despite `RootView` being a
    /// value type: `@State`'s `wrappedValue` setter is `nonmutating`, so
    /// writing `self.model`/`self.onboarding` from a closure captured by an
    /// older copy of `self` still writes through to the SAME shared storage
    /// SwiftUI keeps for this view's identity — the same guarantee the
    /// `.task` closure above already relies on for `model = loaded`.
    private func makeOnboardingModel(for model: AppModel) -> OnboardingModel {
        let database = model.database
        let onboardingModel = OnboardingModel(database: database)
        onboardingModel.onConnected = { [self] record in
            let mailbox = AppModel(database: database, account: record)
            self.model = mailbox
            mailbox.startAutoSync()
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

            if let syncBanner = model.syncBanner {
                VStack(spacing: 0) {
                    Banner(text: syncBanner, role: .warn)
                    Spacer(minLength: 0)
                }
            }

            if model.isPaletteVisible {
                overlay {
                    CommandPaletteView(
                        command: model.command,
                        perform: { model.perform($0) },
                        onClose: { model.isPaletteVisible = false })
                } onDismiss: {
                    model.isPaletteVisible = false
                }
            }

            if model.isSearchVisible {
                overlay {
                    SearchView(
                        search: model.search,
                        onOpen: { threadID in
                            model.isSearchVisible = false
                            model.openThread(threadID)
                        })
                } onDismiss: {
                    model.isSearchVisible = false
                }
            }

            if model.isComposerVisible {
                overlay {
                    ComposerView(
                        composer: model.composer, onClose: { model.isComposerVisible = false })
                } onDismiss: {
                    model.isComposerVisible = false
                }
            }

            sentUndoToast(model)
        }
        // Invisible — installs the app-wide `NSEvent` monitor that drives
        // every keyboard shortcut (see `KeyboardMonitor`/`KeyRouter`).
        .background(KeyboardMonitor(appModel: model))
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
                syncBanner: model.syncBanner,
                // Only "Inbox" is wired to a real Store-backed filter this
                // milestone; pinning the highlight there avoids a misleading
                // "selected but does nothing" affordance for the rest.
                selection: .inbox,
                onSelect: { selection in
                    switch selection {
                    case .inbox:
                        model.inbox.activeSplit = nil
                    case .starred, .snoozed, .sent, .label:
                        // Non-functional this milestone (no Store query backs
                        // them yet) — a deliberate gap, like ThreadView's
                        // AI-summary placeholder.
                        break
                    }
                },
                onSyncNow: { Task { await model.syncNow() } })
                .frame(minWidth: 200, idealWidth: Metrics.sidebarWidth, maxWidth: 300)

            InboxListView(inbox: model.inbox, onOpen: { model.openThread($0) })
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
                }
            }
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
    @ViewBuilder
    private func sentUndoToast(_ model: AppModel) -> some View {
        if model.composer.justSentUndoJobID != nil {
            VStack {
                Spacer(minLength: 0)
                Button(action: { Task { await model.composer.undo() } }) {
                    Toast(text: "Sent · Undo")
                }
                .buttonStyle(.plain)
                .padding(.bottom, Metrics.unit * 8)
            }
        }
    }

    /// A dimmed, click-to-dismiss backdrop behind a centered modal —
    /// shared shape for the palette and search overlays. Matches both
    /// views' own `.shadow(color: .black.opacity(0.4), radius: 24, y: 12)`
    /// styling of the modal itself; this is the scrim BEHIND it.
    private func overlay<Content: View>(
        @ViewBuilder content: () -> Content, onDismiss: @escaping () -> Void
    ) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            content()
        }
    }
}
