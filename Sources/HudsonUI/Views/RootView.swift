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
    public init(model: AppModel) {
        self.databaseURL = nil
        self.isDemo = false
        self._model = State(initialValue: model)
    }

    public var body: some View {
        Group {
            if let model {
                assembled(model)
            } else {
                loadingPlaceholder
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Palette.bgApp)
        .task {
            guard model == nil, let databaseURL else { return }
            model = try? await (isDemo ? AppModel.demo() : AppModel(databaseURL: databaseURL))
        }
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
        }
        // Invisible — installs the app-wide `NSEvent` monitor that drives
        // every keyboard shortcut (see `KeyboardMonitor`/`KeyRouter`).
        .background(KeyboardMonitor(appModel: model))
    }

    private func threePane(_ model: AppModel) -> some View {
        NavigationSplitView {
            SidebarView(
                accountEmail: model.account?.email,
                unreadCount: model.totalUnread,
                labels: model.labels,
                pendingCount: model.pendingCount,
                // Only "Inbox" is wired to a real Store-backed filter this
                // milestone (see `onSelect` below) — pinning the highlight
                // there avoids a misleading "selected but does nothing"
                // affordance for Starred/Snoozed/Sent/labels.
                selection: .inbox,
                onSelect: { selection in
                    switch selection {
                    case .inbox:
                        model.inbox.activeSplit = nil
                    case .starred, .snoozed, .sent, .label:
                        // Non-functional this milestone: Store has no query
                        // backing these yet (only `activeSplit`'s split-key
                        // filter exists, driven by the inbox list's own tab
                        // strip). Real nav lands with a later task's Store
                        // API — matches `ThreadView`'s AI-summary/reply-bar
                        // placeholders: an explicit, deliberate gap, not an
                        // oversight.
                        break
                    }
                })
                // Draggable, within sane bounds — replaces the sidebar's old
                // hard `.frame(width:)` so its divider actually resizes.
                .navigationSplitViewColumnWidth(min: 200, ideal: Metrics.sidebarWidth, max: 320)
        } content: {
            InboxListView(inbox: model.inbox, onOpen: { model.openThread($0) })
                // Draggable list column — replaces the inbox list's old hard
                // `.frame(width:)`. The detail (reading) pane takes whatever
                // space is left and resizes with this divider.
                .navigationSplitViewColumnWidth(min: 320, ideal: Metrics.listWidth, max: 560)
        } detail: {
            // Only mount the full ThreadView (toolbar + reply bar + body) once
            // a thread is actually open. With nothing selected we show a bare
            // centered empty state instead, so the reading pane never presents
            // dead chrome (a Reply bar with nothing to reply to, etc.).
            if model.inbox.selectedThreadID != nil && !model.thread.messages.isEmpty {
                ThreadView(
                    thread: model.thread,
                    onArchive: { Task { try? await model.inbox.archiveSelected() } },
                    onToggleStar: { Task { try? await model.inbox.toggleStarSelected() } })
            } else {
                readingPaneEmptyState
            }
        }
        // The design has no sidebar-collapse affordance (SidebarView's own
        // comment: the hidden-title-bar window reserves the traffic-light
        // inset itself); `NavigationSplitView` otherwise injects one into
        // the toolbar automatically.
        .toolbar(removing: .sidebarToggle)
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
