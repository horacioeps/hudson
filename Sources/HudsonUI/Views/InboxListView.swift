import Foundation
import Store
import SwiftUI

/// The middle pane: the split-tab header plus the scrolling thread list.
/// Binds directly to an `InboxModel` for `tabs`/`rows`/`activeSplit`/
/// `selectedThreadID` — clicking a row both updates the model's selection
/// and calls `onOpen` so the reading pane (a later task) can load the
/// thread. Owns no Store calls itself; `InboxModel` is the sole data source.
public struct InboxListView: View {
    private let inbox: InboxModel
    private let onOpen: (String) -> Void

    public init(inbox: InboxModel, onOpen: @escaping (String) -> Void) {
        self.inbox = inbox
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            list
        }
        // No hard width here anymore — the reading pane must be resizable, so
        // the split divider (not this view) owns the column width. RootView
        // sets a min/ideal/max via `.navigationSplitViewColumnWidth`.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.bgApp)
        // `activeSplit` starts `nil` ("whole inbox", per `InboxModel`'s doc
        // comment) but the tab strip has no dedicated "whole inbox" tab —
        // Gmail's own default is Primary, so a fresh model settles there
        // once, the same way `isActive` below already treats `nil` as
        // Primary for the highlight. A returning selection (non-nil) is
        // left untouched.
        .task {
            if inbox.activeSplit == nil {
                inbox.activeSplit = "primary"
            }
        }
    }

    /// The inbox shows its split-tab strip; a label folder (Sent/Starred/…)
    /// shows a plain title header instead.
    @ViewBuilder
    private var header: some View {
        if inbox.showsSplitTabs {
            tabStrip
        } else {
            HStack {
                Text(inbox.folderTitle)
                    .font(Typography.ui(13, .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 3)
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.unit) {
                ForEach(inbox.tabs) { tab in
                    InboxTab(
                        title: tab.title, count: tab.count, isActive: isActive(tab),
                        action: { inbox.activeSplit = tab.key })
                }
            }
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 2)
        }
    }

    /// `nil` and `"primary"` are the same tab visually — see the `.task`
    /// above for why the model itself resolves to `"primary"` shortly
    /// after this view first appears.
    private func isActive(_ tab: SplitTab) -> Bool {
        (inbox.activeSplit ?? "primary") == tab.key
    }

    @ViewBuilder
    private var list: some View {
        if inbox.rows.isEmpty {
            VStack {
                Text("No messages here")
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.inkTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(inbox.rows, id: \.threadID) { threadRow in
                        row(for: threadRow)
                        if threadRow.threadID != inbox.rows.last?.threadID {
                            Rectangle().fill(Palette.border).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func row(for threadRow: ThreadRow) -> some View {
        Button {
            inbox.selectedThreadID = threadRow.threadID
            onOpen(threadRow.threadID)
        } label: {
            EmailRow(
                row: Self.emailRowData(from: threadRow),
                isSelected: inbox.selectedThreadID == threadRow.threadID,
                isUnread: threadRow.unread)
                // The ENTIRE row rectangle must open the thread, not just the
                // glyphs. An unread/unselected row's background is `.clear`,
                // and under `.buttonStyle(.plain)` a transparent label only
                // hit-tests where it actually draws — so a click in the empty
                // gutter to the right of the snippet, or in the vertical
                // padding, would miss. Filling the width and stamping a
                // rectangular content shape on the LABEL itself (not the outer
                // Button, where it wouldn't affect the label's own hit region)
                // makes every pixel of the 72pt row a valid tap target.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            guard threadRow.threadID == inbox.rows.last?.threadID else { return }
            // TODO(pagination): `InboxModel.rows` comes from a fixed-limit
            // `ValueObservation` (Store Task 3's `observeInboxThreads` doc
            // comment: it re-runs its whole SELECT, capped at `limit`, on
            // every emit — there's no keyset append the way the one-shot
            // `inboxThreads(before:)` supports). `InboxModel` exposes no
            // public way to extend that limit yet, so real "load more"
            // waits on a future `InboxModel.loadMore()` that fetches the
            // next page via `inboxThreads(before:)` and appends it. The
            // demo mailbox (~40 threads) sits well inside the model's
            // current 200-row first page, so this is a no-op today.
        }
    }

    static func emailRowData(from row: ThreadRow) -> EmailRowData {
        EmailRowData(
            fromSummary: row.fromSummary, subject: row.subject,
            snippet: HTMLEntities.decode(row.snippet),
            timeText: formattedTime(epochMilliseconds: row.lastMessageAt),
            hasAttachment: row.hasAttachment, category: row.category, unread: row.unread)
    }

    /// "9:41" for a message from today, "Aug 3" otherwise — matches the
    /// Pencil design's compact timestamp column. `now`/`calendar` are
    /// parameters (not hard-coded `.current`/`Date.now`) purely so a test
    /// can pin them; every call site in this file uses the defaults.
    static func formattedTime(
        epochMilliseconds: Int64, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        let date = Date(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm" : "MMM d"
        return formatter.string(from: date)
    }
}

#Preview {
    let db = try! HudsonDatabase.inMemory()
    let model = InboxModel(database: db, account: "you@hudson.app")
    return InboxListView(inbox: model, onOpen: { _ in })
        .frame(height: 700)
}
