import Foundation
import Store
import SwiftUI

/// Turns a sanitized plain-text body into an `AttributedString` with
/// http/https/mailto links detected and made tappable — so the plain-text
/// fallback (a message with no HTML) still has working links. ONLY those three
/// safe schemes get a link; anything else stays inert text, so a body can't
/// smuggle a `file:`/`javascript:`/custom-scheme link past this. Uses
/// `NSDataDetector`, Foundation's own link scanner (the same one `NSTextView`
/// uses), so detection matches platform behavior. Tapping a rendered link goes
/// through SwiftUI's default `openURL`, which opens it in the user's browser —
/// never in-app.
enum PlainTextLinkifier {
    static func attributed(_ plainText: String) -> AttributedString {
        let mutable = NSMutableAttributedString(string: plainText)
        // Built locally rather than as a shared `static let`: `NSDataDetector`
        // isn't `Sendable`, and the construction cost is negligible next to
        // rendering a message body.
        if let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let whole = NSRange(location: 0, length: (plainText as NSString).length)
            detector.enumerateMatches(in: plainText, range: whole) { match, _, _ in
                guard let url = match?.url, let matchRange = match?.range,
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto"].contains(scheme) else { return }
                mutable.addAttribute(.link, value: url, range: matchRange)
            }
        }
        return AttributedString(mutable)
    }
}

/// A sender's display name and bare address, parsed from an RFC 5322
/// `From:` header. Deliberately independent of `ThreadModel`'s own
/// (private) `senderDisplayName` — this is a lighter-weight parse for VIEW
/// display only (avatar initials, sender/address lines, a search result's
/// "from" text). `fromLine` is untrusted (sender-controlled mail headers),
/// so every function here is pure and total — never throws or crashes on
/// malformed input. Shared by `ThreadView` and `SearchView`.
enum SenderInfo {
    /// The display name in a `Name <email>` header (surrounding
    /// double-quotes stripped), or the full trimmed `fromLine` when there's
    /// no `<...>` address to split off.
    static func name(fromLine: String) -> String {
        let trimmed = fromLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close
        else { return trimmed }
        let namePart = trimmed[trimmed.startIndex..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let unquotedName = unquoted(namePart)
        return unquotedName.isEmpty ? trimmed : unquotedName
    }

    /// The bare email address in a `Name <email>` header, or the full
    /// trimmed `fromLine` when there's no `<...>` to extract from.
    static func address(fromLine: String) -> String {
        let trimmed = fromLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close
        else { return trimmed }
        return String(trimmed[trimmed.index(after: open)..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A single uppercase initial for an avatar glyph — the first character
    /// of `name(fromLine:)`, or "?" when that's empty.
    static func initial(fromLine: String) -> String {
        guard let first = name(fromLine: fromLine).first else { return "?" }
        return String(first).uppercased()
    }

    /// Strips one layer of matching double-quotes (an RFC 5322
    /// quoted-string display name, e.g. `"Ada Lovelace"`), if present.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The reading pane: the open thread's subject/sender header, the
/// AI-summary placeholder, each message's body (newest expanded, older
/// messages collapsed to one-line summaries that expand on click), and a
/// non-functional reply bar. Binds directly to a `ThreadModel` — every
/// mutation (expand/collapse) happens by calling into that model; this view
/// makes no Store calls of its own.
///
/// Archive/Star are the two triage actions wired LIVE this milestone, via
/// caller-supplied closures — `ThreadModel` itself has no triage methods
/// (that lives on `InboxModel`, which a later task's host view already
/// owns), so this view stays agnostic of exactly how those two actions are
/// performed. Snooze and "⋯ more" are placeholders (M6), and the AI-summary
/// chip and the reply bar are NON-FUNCTIONAL placeholders (M7/M5): tapping
/// either only shows a `Toast` naming the milestone it arrives in — zero
/// network egress, zero sending, per this milestone's privacy constraint.
public struct ThreadView: View {
    private let thread: ThreadModel
    private let onArchive: () -> Void
    private let onToggleStar: () -> Void

    /// Toast text currently shown above the reply bar, or `nil` when none is
    /// visible. Cleared automatically a couple seconds after `showToast`.
    @State private var toastText: String?

    public init(
        thread: ThreadModel, onArchive: @escaping () -> Void, onToggleStar: @escaping () -> Void
    ) {
        self.thread = thread
        self.onArchive = onArchive
        self.onToggleStar = onToggleStar
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            if thread.messages.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        summaryChip
                            .padding(.top, Metrics.unit * 5)
                        messageList
                            .padding(.top, Metrics.unit * 6)
                    }
                    .padding(.horizontal, Metrics.unit * 8)
                    .padding(.top, Metrics.unit * 6)
                    .padding(.bottom, Metrics.unit * 8)
                }
            }
            replyBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgSurface)
        .overlay(alignment: .bottom) {
            if let toastText {
                Toast(text: toastText)
                    .padding(.bottom, Metrics.unit * 20)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Metrics.unit) {
            QuietButton(title: "Archive", action: onArchive)
            QuietButton(title: "Snooze", action: { showToast("Coming soon") })
            QuietButton(title: "Star", action: onToggleStar)
            Spacer(minLength: Metrics.unit)
            QuietButton(title: "⋯", action: { showToast("More actions coming soon") })
        }
        .padding(.horizontal, Metrics.unit * 4)
        .padding(.vertical, Metrics.unit * 3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    // MARK: - Header (subject + sender row)

    /// The most-recently-dated message, or `nil` before `thread.open` has
    /// emitted anything — backs both `header`'s sender row and
    /// `expandedMessage`'s "skip the redundant sender line" check.
    private var newestMessage: ThreadMessage? {
        thread.messages.max(by: { $0.row.internalDate < $1.row.internalDate })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 4) {
            Text(thread.subject)
                .font(Typography.serif(24, .semibold))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            if let newestMessage {
                senderRow(for: newestMessage.row)
            }
        }
    }

    private func senderRow(for row: MessageRow) -> some View {
        HStack(spacing: Metrics.unit * 3) {
            avatar(fromLine: row.fromLine)
            VStack(alignment: .leading, spacing: 2) {
                Text(SenderInfo.name(fromLine: row.fromLine))
                    .font(Typography.ui(13, .semibold))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                Text(SenderInfo.address(fromLine: row.fromLine))
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.inkSecondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Metrics.unit)
            Text(InboxListView.formattedTime(epochMilliseconds: row.internalDate))
                .font(Typography.ui(12))
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func avatar(fromLine: String) -> some View {
        Circle()
            .fill(Palette.accentSoft)
            // 32pt — derived from `unit` (8×4), not a Pencil-exact literal.
            .frame(width: Metrics.unit * 8, height: Metrics.unit * 8)
            .overlay(
                Text(SenderInfo.initial(fromLine: fromLine))
                    .font(Typography.ui(13, .semibold))
                    .foregroundStyle(Palette.ink)
            )
    }

    // MARK: - AI summary placeholder

    private var summaryChip: some View {
        Button(action: { showToast("AI summaries arrive with M7") }) {
            Text("✦ Summarize thread")
                .font(Typography.ui(12, .medium))
                .foregroundStyle(Palette.aiInk)
                .padding(.vertical, Metrics.unit * 2)
                .padding(.horizontal, Metrics.unit * 3)
                .background(Palette.aiBg)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Messages (newest expanded, older collapsed)

    private var messageList: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 3) {
            ForEach(thread.messages) { message in
                if message.isExpanded {
                    expandedMessage(message)
                } else {
                    collapsedMessage(message)
                }
            }
        }
    }

    /// A one-line "sender + snippet" summary for a collapsed older message;
    /// clicking it expands it in place via `ThreadModel.toggleExpanded`.
    private func collapsedMessage(_ message: ThreadMessage) -> some View {
        Button(action: { thread.toggleExpanded(message.id) }) {
            HStack(spacing: Metrics.unit * 2) {
                Text(SenderInfo.name(fromLine: message.row.fromLine))
                    .font(Typography.ui(13, .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(message.row.snippet)
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.unit * 3)
            .padding(.vertical, Metrics.unit * 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func expandedMessage(_ message: ThreadMessage) -> some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 3) {
            // `header` above already shows sender/time for the NEWEST
            // message, so repeating it here would be redundant — only an
            // older message the reader expands by hand gets its own compact
            // sender/time line.
            if message.id != newestMessage?.id {
                HStack(spacing: Metrics.unit * 2) {
                    Text(SenderInfo.name(fromLine: message.row.fromLine))
                        .font(Typography.ui(12, .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: Metrics.unit)
                    Text(InboxListView.formattedTime(epochMilliseconds: message.row.internalDate))
                        .font(Typography.ui(11))
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            bodyText(for: message)
            let filenames = Self.attachmentFilenames(for: message)
            if !filenames.isEmpty {
                attachmentChips(filenames)
            }
        }
        .padding(.vertical, Metrics.unit * 2)
    }

    @ViewBuilder
    private func bodyText(for message: ThreadMessage) -> some View {
        if let rawHTML = message.rawHTML, !rawHTML.isEmpty {
            // Real HTML mail — render it in the privacy-sandboxed WKWebView
            // (remote loads blocked by default; see `HTMLMessageView` for the
            // full remote-blocking rationale). Links open in the browser.
            HTMLMessageView(rawHTML: rawHTML, remoteURLs: message.remoteURLs)
                .frame(maxWidth: 680, alignment: .leading)
        } else if let bodyText = message.bodyText, !bodyText.isEmpty {
            // Plain-text fallback: selectable, with bare URLs linkified so
            // they're still tappable even with no HTML.
            Text(PlainTextLinkifier.attributed(bodyText))
                .font(Typography.serif(15))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
        } else {
            // `bodyText`/`rawHTML` are nil until `ThreadModel` finishes
            // fetching (eagerly for the newest message, lazily on expand for
            // everything else) — a subtle placeholder rather than an empty gap
            // while that read is in flight.
            Text("Loading…")
                .font(Typography.serif(15))
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: 680, alignment: .leading)
        }
    }

    /// Filenames to render as attachment `Chip`s for one expanded message.
    /// Always `[]` today: `MessageRow`/`ThreadMessage` carry no attachment
    /// metadata — Store records it in the `attachments` table
    /// (`AttachmentMeta`, see `StoreBodies.saveBody`) but exposes no public
    /// read accessor for it yet, and adding one is out of this task's scope
    /// (only the three view files in the brief change here). The chip
    /// rendering below is real, using the same `Chip(.neutral)` role as
    /// everywhere else in the app — once a real accessor lands, only this
    /// function's body changes.
    private static func attachmentFilenames(for message: ThreadMessage) -> [String] {
        []
    }

    private func attachmentChips(_ filenames: [String]) -> some View {
        HStack(spacing: Metrics.unit) {
            ForEach(filenames, id: \.self) { filename in
                Chip(text: filename, role: .neutral)
            }
        }
    }

    // MARK: - Empty state (no thread open yet)

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Text("Select a thread to read it here.")
                .font(Typography.ui(13))
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Reply bar (non-functional — composer is M5)

    private var replyBar: some View {
        HStack {
            QuietButton(title: "Reply", action: { showToast("Sending arrives with M5") })
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.unit * 4)
        .padding(.vertical, Metrics.unit * 3)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
        .background(Palette.bgSurface)
    }

    // MARK: - Toast

    private func showToast(_ text: String) {
        toastText = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastText == text {
                toastText = nil
            }
        }
    }
}

#Preview {
    // Unseeded — `ThreadModel.open` is never called, so this renders the
    // empty state. The render smoke test exercises a fully seeded, opened
    // thread instead (see `RenderSmokeTests.threadViewRendersWithSeededThread`).
    let db = try! HudsonDatabase.inMemory()
    let model = ThreadModel(database: db, account: "you@hudson.app")
    return ThreadView(thread: model, onArchive: {}, onToggleStar: {})
        .frame(width: 760, height: 700)
}
