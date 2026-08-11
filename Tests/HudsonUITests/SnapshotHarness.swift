import AppKit
import Store
import SwiftUI
import Testing

@testable import HudsonUI

/// Controller-only fidelity harness: renders the assembled UI to PNGs via
/// SwiftUI's offscreen `ImageRenderer` (no window server needed, unlike a
/// live `screencapture`). Gated behind `HUDSON_SNAPSHOT=1` so it never runs
/// in the normal suite. Output dir via `HUDSON_SNAPSHOT_DIR` (defaults to the
/// session scratchpad). `NavigationSplitView` can't be bitmapped without a
/// real window, so the three panes are composed manually here at fixed widths
/// — mirroring `RootView.threePane`'s exact call sites — purely for the image.
@MainActor
struct SnapshotHarness {
    static var enabled: Bool { ProcessInfo.processInfo.environment["HUDSON_SNAPSHOT"] == "1" }

    static var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["HUDSON_SNAPSHOT_DIR"]
            ?? FileManager.default.temporaryDirectory.appending(path: "hudson-snapshots").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func renderScreens() async throws {
        guard Self.enabled else { return }  // opt-in only

        let model = try await AppModel.demo()

        // Wait (bounded) for the inbox observation's first emit.
        try await waitUntil { !model.inbox.rows.isEmpty }
        #expect(!model.inbox.rows.isEmpty)

        // Open a multi-message thread so the reading pane shows real content,
        // and select it so the list shows the selected-row treatment.
        let target = model.inbox.rows.first(where: { $0.messageCount > 1 }) ?? model.inbox.rows[0]
        model.openThread(target.threadID)
        try await waitUntil {
            model.thread.messages.contains { $0.isExpanded && $0.bodyText != nil }
        }

        let dir = Self.outputDir

        // 1. Main three-pane.
        try await render(threePane(model), width: 1240, height: 780, to: dir.appending(path: "hudson-3pane.png"))

        // 2. Command palette over the three-pane.
        model.command.reload(splits: model.inbox.tabs, hasSelection: true)
        model.command.filter()
        let palette = ZStack {
            threePane(model)
            Color.black.opacity(0.4)
            CommandPaletteView(command: model.command, perform: { _ in }, onClose: {})
        }
        try await render(palette, width: 1240, height: 780, to: dir.appending(path: "hudson-palette.png"))

        // 3. Search overlay over the three-pane.
        model.search.query = "denver"
        model.search.queryChanged()
        try await waitUntil { !model.search.hits.isEmpty || !model.search.isSearching }
        let search = ZStack {
            threePane(model)
            Color.black.opacity(0.4)
            SearchView(search: model.search, onOpen: { _ in })
        }
        try await render(search, width: 1240, height: 780, to: dir.appending(path: "hudson-search.png"))

        // 4. The REAL assembled RootView (HSplitView 3-pane) — verifies the
        //    actual container/dividers, not just the manual composition above.
        model.isSearchVisible = false
        try await render(RootView(model: model), width: 1240, height: 780, to: dir.appending(path: "hudson-rootview.png"))

        print("SNAPSHOTS_WRITTEN_TO \(dir.path)")
    }

    /// The three panes composed as a plain HStack (stand-in for the
    /// window-dependent `NavigationSplitView`), at the design widths.
    @ViewBuilder
    private func threePane(_ model: AppModel) -> some View {
        HStack(spacing: 0) {
            SidebarView(
                accountEmail: model.account?.email,
                unreadCount: model.inbox.rows.count(where: { $0.unread }),
                labels: model.labels,
                pendingCount: model.pendingCount,
                selection: .inbox,
                onSelect: { _ in }
            )
            .frame(width: Metrics.sidebarWidth)

            InboxListView(inbox: model.inbox, onOpen: { _ in })
                .frame(width: Metrics.listWidth)

            ThreadView(
                thread: model.thread, summary: model.summary, onArchive: {}, onToggleStar: {},
                onReply: {}, onSummarize: {})
                .frame(maxWidth: .infinity)
        }
        .background(Palette.bgApp)
    }

    /// Mounts the view in an OFFSCREEN `NSWindow` and captures the real
    /// AppKit layer tree via `cacheDisplay` — unlike `ImageRenderer`, this
    /// lays out `ScrollView`/`LazyVStack`, fires `.onAppear`, and renders the
    /// NSScrollView-backed content. It reads the window's own backing store
    /// (not the display), so it needs no screen-recording permission.
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, to url: URL) async throws {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = frame
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()

        // Let onAppear-driven state, the observation, and ScrollView layout
        // settle, then force a synchronous display cycle before capturing.
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        window.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.renderFailed(url.lastPathComponent)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodeFailed(url.lastPathComponent)
        }
        try data.write(to: url)
        window.orderOut(nil)
    }

    /// Polls `condition` up to ~3s (60 × 50ms) — the observation/body-load
    /// tasks are async, so give them a bounded window to land before render.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<60 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

enum SnapshotError: Error { case renderFailed(String), encodeFailed(String) }
