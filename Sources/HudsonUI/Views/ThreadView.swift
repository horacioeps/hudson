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

    /// Up to TWO uppercase initials for the message-header avatar ("SL",
    /// "DO"), per the Pencil design. Uses the first letter of the first and
    /// last words of the display name; falls back to the first two letters of
    /// a single-word name or address local part, so the badge is never a lone
    /// character next to two-letter neighbours.
    static func initials(fromLine: String) -> String {
        let display = name(fromLine: fromLine)
        let address = address(fromLine: fromLine)
        // With no `Name <addr>` form, `name` echoes the whole address — and
        // splitting THAT on "." would take initials from the domain
        // ("derek.osei@brightleaf.example" → "DE"). Use the local part.
        let source = display.caseInsensitiveCompare(address) == .orderedSame
            ? String(address.prefix(while: { $0 != "@" }))
            : display
        let words = source
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
            .filter { $0.contains(where: \.isLetter) }
        guard let first = words.first else { return "?" }
        if words.count >= 2, let last = words.last?.first {
            return (String(first.prefix(1)) + String(last)).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    /// Strips one layer of matching double-quotes (an RFC 5322
    /// quoted-string display name, e.g. `"Ada Lovelace"`), if present.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A natively-rendered message body: the reply itself, and — when the message
/// quoted the thread beneath it — a "···" pill that reveals that history in
/// place. Its own `View` rather than a function on `ThreadView` because the
/// shown/hidden state must live per message and survive re-renders.
///
/// Both native paths funnel here (parsed HTML and plain text), so the toggle
/// behaves identically whichever produced the text. The web-view path keeps
/// its own CSS/JS equivalent — it renders a document, not an
/// `AttributedString`, so it can't share this one.
private struct CollapsibleBody: View {
    let new: AttributedString
    let quoted: AttributedString

    @State private var showQuoted = false

    private var hasQuotedHistory: Bool { !quoted.characters.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 2) {
            if !new.characters.isEmpty {
                Text(new).textSelection(.enabled)
            }
            if hasQuotedHistory {
                quoteToggle
                if showQuoted {
                    Text(quoted)
                        .textSelection(.enabled)
                        .padding(.leading, Metrics.unit * 2)
                        // A rail marking where the reply ends and the thread's
                        // own history begins.
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Palette.border).frame(width: 2)
                        }
                        .transition(Motion.reveal)
                }
            }
        }
        // Eased, not sprung: a quoted chain can run thousands of points tall,
        // and a spring would spend its whole settle re-laying-out that
        // `AttributedString` a frame at a time. Scoped to `showQuoted` so a
        // body landing from a fetch — which rewrites `new`/`quoted` outright —
        // never rides an animation.
        .animation(Motion.settle, value: showQuoted)
        // Defaults only: the parsed-HTML path sets a font and color per run,
        // and those win over these modifiers. The plain-text path carries no
        // attributes of its own, so it inherits them.
        .font(Typography.ui(BodyAttributedString.bodySize))
        .foregroundStyle(Palette.ink)
        .lineSpacing(BodyAttributedString.bodyLineSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pencil spells this as plain text — "••• Show quoted text", 12/600 in
    /// `$ink-tertiary` — rather than the pill it used to be, so it sits
    /// quietly at the end of the body instead of competing with it.
    private var quoteToggle: some View {
        Button(action: { showQuoted.toggle() }) {
            Text(showQuoted ? "••• Hide quoted text" : "••• Show quoted text")
                .font(Typography.ui(12, .semibold))
                .foregroundStyle(Palette.inkTertiary)
                // Swap the word in place rather than letting the label pop:
                // it is the only part of the toggle that changes, so it should
                // dissolve, and faster than the block it is revealing.
                .contentTransition(.opacity)
                .animation(Motion.crossfade, value: showQuoted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Lights a row while the pointer is over it. A `ViewModifier` with its own
/// `@State` rather than a `hoveredMessageID` on `ThreadView`, so crossing a
/// card boundary invalidates that one row instead of re-rendering every
/// message in the thread. Fades via opacity rather than swapping to
/// `Color.clear`, which would interpolate through transparent black.
private struct HoverFill: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                Palette.bgHover
                    .opacity(isHovering ? 1 : 0)
                    // Out is slower than in on purpose: a pointer sweeping a
                    // long thread would otherwise leave a trail of lit rows.
                    .animation(isHovering ? Motion.hoverIn : Motion.hoverOut, value: isHovering))
            .onHover { isHovering = $0 }
    }
}

/// The per-message reply affordance. Its own `View` (not a bare `Button` in
/// `messageHeader`) so the hover state is per row, and because the whole
/// header is the collapse target — a plain icon here would toggle the card
/// instead of starting a reply.
private struct ReplyButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 13))
                // Never faded in from nothing on card hover: this is the only
                // per-message reply entry point, and hiding it until hover
                // would trade discoverability for polish.
                .foregroundStyle(isHovering ? Palette.ink : Palette.inkTertiary)
                .animation(isHovering ? Motion.hoverIn : Motion.hoverOut, value: isHovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply")
        .onHover { isHovering = $0 }
    }
}

/// The reading pane: the open thread's subject/sender header, the
/// AI-summary placeholder, each message's body (newest expanded, older
/// messages collapsed to one-line summaries that expand on click), and a
/// non-functional reply bar. Binds directly to a `ThreadModel` — every
/// mutation (expand/collapse) happens by calling into that model; this view
/// makes no Store calls of its own.
///
/// Archive/Star/Reply are the triage/compose actions wired LIVE, via
/// caller-supplied closures — `ThreadModel` itself has no triage methods
/// (that lives on `InboxModel`) and no compose methods (that lives on
/// `AppModel.composer`, Task 4's `replyToOpenThread()`), so this view stays
/// agnostic of exactly how any of the three are performed. Snooze and "⋯
/// more" are still placeholders (M6).
///
/// The AI-summary chip is LIVE (Task 5): tapping it runs `onSummarize`, which
/// funnels to `SummaryModel.summarize` — the ONE explicit user action that
/// mints the `.summarize` `Invocation`. The chip renders the streamed summary
/// (or the "turn AI on" banner when the feature isn't opted in) from the bound
/// `summary` model. It NEVER runs on its own — no summarize-on-open or
/// -on-scroll — per this milestone's Privacy #1 constraint.
public struct ThreadView: View {
    private let thread: ThreadModel
    private let summary: SummaryModel
    private let onArchive: () -> Void
    private let onToggleStar: () -> Void
    private let onReply: () -> Void
    private let onSummarize: () -> Void

    /// Toast text currently shown above the reply bar, or `nil` when none is
    /// visible. Cleared automatically a couple seconds after `showToast`.
    @State private var toastText: String?

    public init(
        thread: ThreadModel, summary: SummaryModel, onArchive: @escaping () -> Void,
        onToggleStar: @escaping () -> Void, onReply: @escaping () -> Void,
        onSummarize: @escaping () -> Void
    ) {
        self.thread = thread
        self.summary = summary
        self.onArchive = onArchive
        self.onToggleStar = onToggleStar
        self.onReply = onReply
        self.onSummarize = onSummarize
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            if thread.messages.isEmpty {
                emptyState
            } else {
                // Pencil pins the thread header and scrolls only the messages,
                // so the subject and the AI bar stay put while a long
                // conversation moves under them.
                header
                ScrollView {
                    messageList
                        .padding(.horizontal, Metrics.unit * 7)
                        .padding(.top, Metrics.unit * 4)
                        .padding(.bottom, Metrics.unit * 6)
                }
            }
            replyBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bgApp)
        .overlay(alignment: .bottom) {
            ZStack {
                if let toastText {
                    Toast(text: toastText)
                        // Tapping ⋯ while the Snooze toast is still up would
                        // otherwise swap the words inside a stationary pill.
                        // A distinct identity makes it a real replacement, so
                        // the second message cross-fades in.
                        .id(toastText)
                        .transition(Motion.toast)
                }
            }
            // Arriving is placed, expiring is not a decision the user made —
            // so it recedes rather than being cut. Confined to the overlay: an
            // `.animation` up on `body` would sweep the whole pane's layout
            // into a toast's transaction.
            .animation(toastText == nil ? Motion.dismiss : Motion.present, value: toastText)
            .padding(.bottom, Metrics.unit * 20)
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

    /// Subject, participant meta, and the AI chip — Pencil "Thread Header":
    /// `$font-ui` 18/700 subject over a 12pt tertiary meta line, gap 10.
    /// The sender/address row that used to live here is gone: senders now
    /// belong to each message's own header, so repeating the newest one above
    /// the stack was duplicate information.
    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 2.5) {
            Text(thread.subject)
                .font(Typography.ui(18, .bold))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            Text(metaLine)
                .font(Typography.ui(12))
                .foregroundStyle(Palette.inkTertiary)
                .textSelection(.enabled)
            summaryChip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.unit * 7)
        .padding(.top, Metrics.unit * 5)
        .padding(.bottom, Metrics.unit * 3.5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    /// "3 messages · Sarah Lin, David Okafor, you" — count plus the thread's
    /// distinct senders, which `ThreadModel.participants` already derives.
    private var metaLine: String {
        let count = thread.messages.count
        let noun = count == 1 ? "message" : "messages"
        let people = thread.participants
        return people.isEmpty ? "\(count) \(noun)" : "\(count) \(noun) · \(people)"
    }

    // MARK: - AI summary (live — explicit tap only, opt-in gated)

    /// The amber chip plus, below it, whatever the bound `SummaryModel`
    /// currently holds: the streamed summary, the "turn AI on" setup banner
    /// (not opted in), or a failure banner. All three sit in the same
    /// `aiBg`/`aiInk` treatment as the chip, and NONE of it appears until the
    /// user taps — no summarize-on-open, per Privacy #1.
    /// Pencil draws this chip already holding a summary, as a permanent part
    /// of the thread header. Rendering it that way would mean summarizing on
    /// open, which Privacy #1 forbids — so the mock is read as the POST-TAP
    /// state: same full-width `$ai-bg` bar, same note icon and caret, but the
    /// label invites the run and the summary text only replaces it once the
    /// user has asked for one.
    private var summaryChip: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 3) {
            Button(action: onSummarize) {
                HStack(spacing: Metrics.unit * 2.25) {
                    Image(systemName: "note.text")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.aiInk)
                    Text(summaryChipLabel)
                        .font(Typography.ui(12.5, .medium))
                        .foregroundStyle(Palette.aiInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.aiInk)
                }
                .padding(.vertical, Metrics.unit * 2)
                .padding(.horizontal, Metrics.unit * 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                // `.disabled` alone changes nothing visually here, so the bar
                // dims itself while the provider is talking.
                .background(Palette.aiBg.opacity(summary.isStreaming ? 0.75 : 1))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
                // Tokens arrive one delta at a time and each one can add a
                // line. Pinning them is what keeps the chip's growth a single
                // settle at the end of the run instead of a text field
                // twitching for the length of the stream.
                .animation(nil, value: summary.text)
                // The two boundaries that ARE worth animating: the label
                // cross-fading into "Summarizing…", and the chip settling to
                // however many lines the finished summary wraps to.
                .animation(Motion.settle, value: summary.isStreaming)
            }
            .buttonStyle(.plain)
            .disabled(summary.isStreaming)

            if summary.needsSetup {
                summaryNote(SummaryModel.setupBannerText)
                    .transition(Motion.reveal)
            } else if let banner = summary.banner {
                summaryNote(banner)
                    .transition(Motion.reveal)
            }
            // No separate summary block: once a summary exists it becomes the
            // chip's own label, which is how Pencil draws it — one AI bar in
            // the header, not a bar plus a panel repeating it.
        }
        // Both notes are strictly gated behind a tap and land once per run, so
        // unfolding them out from under the chip reads as an answer to that
        // tap rather than as the UI moving on its own.
        .animation(Motion.settle, value: summary.needsSetup)
        .animation(Motion.settle, value: summary.banner)
    }

    private var summaryChipLabel: String {
        if summary.isStreaming { return "Summarizing…" }
        return summary.text.isEmpty ? "Summarize this thread" : summary.text
    }

    /// A compact note under the chip — the setup incantation or a failure
    /// message — in the same AI treatment, slightly dimmed.
    private func summaryNote(_ message: String) -> some View {
        Text(message)
            .font(Typography.ui(12))
            .foregroundStyle(Palette.aiInk)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.unit * 3)
            .background(Palette.aiBg)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
    }

    // MARK: - Messages (each a surface card, per Pencil "Thread (Expanded)")

    /// The conversation: one `$bg-surface` card per message on the `$bg-app`
    /// ground, 10pt apart. Every message opens expanded (see
    /// `ThreadModel.reconcile`); clicking a header collapses one back to a
    /// single line.
    private var messageList: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 2.5) {
            ForEach(thread.messages) { message in
                messageCard(message)
            }
        }
    }

    private func messageCard(_ message: ThreadMessage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            messageHeader(message)
            if message.isExpanded {
                bodyText(for: message)
                    .padding(.horizontal, Metrics.unit * 4)
                    .padding(.top, Metrics.unit * 3.5)
                    .padding(.bottom, Metrics.unit * 4)
                    // No animation attached to the transition, deliberately: a
                    // transition carrying its own `.animation` runs on EVERY
                    // insertion, and only one of those is a user expanding a
                    // card. The other two are mount and content arrival —
                    // switching threads mounts a card per message, and each
                    // body then lands from its own fetch and swaps this
                    // subtree a second time, so a self-animating transition
                    // fires twice per message at staggered times. That reads
                    // as jitter, not polish.
                    //
                    // Bare, it inherits the card's `.animation(_:value:)`
                    // below, which only opens a transaction when `isExpanded`
                    // actually changes. Mount and hydration carry no ambient
                    // animation, so they land in one frame.
                    .transition(Motion.reveal)
                if !message.attachments.isEmpty {
                    attachmentChips(message.attachments)
                        .padding(.horizontal, Metrics.unit * 4)
                        .padding(.bottom, Metrics.unit * 3.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(Palette.border, lineWidth: 1))
        // The signature gesture. Bound to `isExpanded` alone, never to
        // `message`: `toggleExpanded` also spawns a fetch that later writes
        // `bodyText`/`attachments`, and those arrive on their own schedule —
        // animating them would make a card the reader is mid-sentence in grow
        // under their eyes. A value-scoped animation leaves them untouched,
        // which is also why the attachment strip appears instantly on
        // hydration but rides the expand when the user asks for it.
        .animation(message.isExpanded ? Motion.expand : Motion.collapse, value: message.isExpanded)
    }

    /// Avatar, sender, recipients + time, and the reply affordance. The whole
    /// row is the collapse/expand target, which is why the reply arrow is a
    /// `Button` of its own rather than a bare icon — otherwise clicking it
    /// would toggle the card instead of starting a reply.
    private func messageHeader(_ message: ThreadMessage) -> some View {
        HStack(spacing: Metrics.unit * 2.5) {
            // Keyed on the FROM address rather than the SENT label so the
            // badge always agrees with the name printed beside it — a message
            // labelled SENT but bearing someone else's From would otherwise
            // render their name over the "you" swatch.
            SenderAvatar(
                fromLine: message.row.fromLine,
                isYou: SenderInfo.address(fromLine: message.row.fromLine)
                    .caseInsensitiveCompare(thread.account) == .orderedSame)
            VStack(alignment: .leading, spacing: 1) {
                Text(SenderInfo.name(fromLine: message.row.fromLine))
                    .font(Typography.ui(13, .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(
                    MessageHeaderText.recipientLine(
                        toLine: message.row.toLine,
                        internalDate: message.row.internalDate,
                        account: thread.account))
                    .font(Typography.ui(11.5))
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Metrics.unit)
            // A collapsed card has no body, so its snippet stands in for one.
            if !message.isExpanded {
                Text(HTMLEntities.decode(message.row.snippet))
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .trailing)
                    // Dissolves in place — never slides — because the reply
                    // arrow to its right must hold still. Bare for the same
                    // reason as the body's transition above: it inherits the
                    // card's transaction, so it moves only when the reader
                    // opens or closes the card, never on mount.
                    .transition(.opacity)
            }
            ReplyButton(action: onReply)
        }
        .padding(.horizontal, Metrics.unit * 4)
        .padding(.vertical, Metrics.unit * 3)
        .contentShape(Rectangle())
        .onTapGesture { thread.toggleExpanded(message.id) }
        // Nothing else tells the reader this row is the expand/collapse
        // target, so the fill is the affordance, not decoration. It sits under
        // the card's `clipShape`, so it respects the corner radius.
        .modifier(HoverFill())
    }

    @ViewBuilder
    private func bodyText(for message: ThreadMessage) -> some View {
        if let rawHTML = message.rawHTML, !rawHTML.isEmpty,
            let html = String(data: rawHTML, encoding: .utf8),
            SimpleBody.isSimple(
                html: html, visibleTextLength: message.bodyText?.count ?? 0) {
            // Prose mail: re-rendered in Hudson's OWN type on the app's dark
            // ground, with every sender font and color discarded. No web view
            // and no white card — see `SimpleBody` for why this is safe.
            nativeBody(html: html)
        } else if let rawHTML = message.rawHTML, !rawHTML.isEmpty {
            // Rich mail (a newsletter, a receipt) — its meaning lives in the
            // layout and images, so it keeps the privacy-sandboxed WKWebView
            // and its white card (remote loads blocked by default; see
            // `HTMLMessageView`). Links open in the browser.
            HTMLMessageView(rawHTML: rawHTML, remoteURLs: message.remoteURLs)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let bodyText = message.bodyText, !bodyText.isEmpty {
            plainTextBody(bodyText)
        } else if !message.row.snippet.isEmpty {
            // No body yet — sync hasn't hydrated this message, or an on-demand
            // fetch is still in flight. Gmail's snippet IS the opening of the
            // message, so showing it beats a placeholder: the reader gets the
            // gist immediately and the full text replaces it when it lands.
            //
            // This matters much more now that every message opens expanded.
            // Under the old newest-only default a body-less message was
            // collapsed and its emptiness never visible; today an unhydrated
            // one would otherwise sit on "Loading…" indefinitely — and during
            // a large mailbox's backfill, many of them would.
            Text(HTMLEntities.decode(message.row.snippet))
                .font(Typography.ui(BodyAttributedString.bodySize))
                .foregroundStyle(Palette.inkSecondary)
                .lineSpacing(BodyAttributedString.bodyLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Loading…")
                .font(Typography.ui(BodyAttributedString.bodySize))
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Prose mail rendered natively: parsed into semantic spans, mapped onto
    /// Hudson's own type, with the quoted history split off behind the "···"
    /// toggle.
    ///
    /// The parse runs per render rather than being cached on `ThreadMessage`.
    /// It's a single O(n) scan over a body that reached this path precisely
    /// because it's prose — a few KB — so it costs tens of microseconds
    /// against a 16ms frame. If a profile ever says otherwise, the place to
    /// cache it is next to the body in `ThreadModel.fetchAndCacheBody`, which
    /// already treats a hydrated body as immutable.
    private func nativeBody(html: String) -> some View {
        let parsed = MessageBodyParser.parse(html: html)
        return CollapsibleBody(
            new: BodyAttributedString.make(parsed.new),
            quoted: BodyAttributedString.make(parsed.quoted))
    }

    /// Plain-text fallback: bare URLs linkified so they're still tappable with
    /// no HTML, and — new here — the quoted history split off exactly like the
    /// HTML path's. This path used to collapse nothing at all, so a plain-text
    /// reply rendered its whole ancestry inline.
    private func plainTextBody(_ text: String) -> some View {
        let (new, quoted) = QuotedText.split(text)
        return CollapsibleBody(
            new: PlainTextLinkifier.attributed(new),
            quoted: quoted.isEmpty ? AttributedString() : PlainTextLinkifier.attributed(quoted))
    }

    /// Attachment chips, per Pencil: a `$bg-sunken` pill with a 1px `$border`,
    /// carrying a kind icon, the filename at 12/600, and a human-readable
    /// size at 11 tertiary. These render real data now — `saveBody` has always
    /// written the `attachments` table, and `HudsonDatabase.attachments`
    /// finally reads it back.
    private func attachmentChips(_ attachments: [AttachmentMeta]) -> some View {
        HStack(spacing: Metrics.unit * 2) {
            ForEach(attachments, id: \.id) { attachment in
                HStack(spacing: Metrics.unit * 2) {
                    Image(systemName: MessageHeaderText.attachmentIcon(forMimeType: attachment.mimeType))
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.inkSecondary)
                    Text(attachment.filename)
                        .font(Typography.ui(12, .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(MessageHeaderText.attachmentSize(attachment.size))
                        .font(Typography.ui(11))
                        .foregroundStyle(Palette.inkTertiary)
                }
                .padding(.horizontal, Metrics.unit * 2.5)
                .padding(.vertical, Metrics.unit * 1.75)
                .background(Palette.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                        .strokeBorder(Palette.border, lineWidth: 1))
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

    // MARK: - Reply bar

    /// Pencil replaces the old "Reply" button with a field-shaped affordance:
    /// a `$bg-surface` rounded box with a `$border-strong` edge, holding the
    /// prompt and its shortcut hints plus the AI-draft glyph. It's still a
    /// button — tapping anywhere opens the composer — but it reads as the
    /// place a reply gets typed, which is the point.
    private var replyBar: some View {
        HStack {
            Button(action: onReply) {
                HStack(spacing: Metrics.unit * 2.5) {
                    Text("Reply all…  ·  R to reply, ⌘J for an AI draft")
                        .font(Typography.ui(13))
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "quote.opening")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.aiInk)
                }
                .padding(.horizontal, Metrics.unit * 3.5)
                .padding(.vertical, Metrics.unit * 2.5)
                .background(Palette.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                        .strokeBorder(Palette.borderStrong, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.unit * 7)
        .padding(.top, Metrics.unit * 3.5)
        .padding(.bottom, Metrics.unit * 4.5)
        .background(Palette.bgApp)
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
    let summary = SummaryModel(database: db, account: "you@hudson.app")
    return ThreadView(
        thread: model, summary: summary, onArchive: {}, onToggleStar: {}, onReply: {},
        onSummarize: {})
        .frame(width: 760, height: 700)
}
