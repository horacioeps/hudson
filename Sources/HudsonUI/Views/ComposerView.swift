import Store
import SwiftUI

/// The compose sheet: new-message and reply drafting, bound directly to a
/// `ComposerModel` (Task 2) — this view makes no Store/Send calls of its
/// own, matching every other Hudson view's "presentational only" contract
/// (`ThreadView`, `SearchView`, `CommandPaletteView`). Mirrors the Pencil
/// composer frame (`h5n209`, "Composer + AI Draft") MINUS its right-hand AI
/// Draft panel — that panel is a later milestone's real feature; here it's
/// only the non-functional placeholder chip the design calls for in reply
/// mode (see `draftPlaceholderChip`).
///
/// **Layout:** a floating card (matches `CommandPaletteView`/`SearchView`'s
/// own self-styled-modal convention) with a To/Cc header, a serif body
/// editor, and a footer holding Send/Cancel. `⌘Return` sends via a real
/// `.keyboardShortcut` on the Send button (works regardless of which field
/// has focus — an AppKit window checks ⌘-equivalents before first responder
/// gets the keystroke); `Esc` closes via `.cancelAction` on Cancel. Neither
/// depends on `RootView`'s global `KeyboardMonitor` (Task 4's concern) —
/// both shortcuts are self-contained to this view.
///
/// **Privacy #1.** This view never calls anything network-shaped itself: a
/// send only happens because the user tapped (or ⌘Return'd) the real Send
/// button, which calls straight through to `ComposerModel.send()` — the
/// same enqueue/undo-hold path Task 2 already tested. Nothing here
/// auto-sends or auto-saves to the wire.
public struct ComposerView: View {
    private let composer: ComposerModel
    /// Dismisses the sheet — supplied by the host (Task 4's `RootView`), not
    /// stored on `ComposerModel` itself. Distinct from `ComposerModel.onClose`
    /// (which the model itself fires on a SUCCESSFUL send, so the presenter
    /// can dismiss then too) — this is the Cancel/Esc path, which must be
    /// able to dismiss without ever calling `send()`.
    private let onClose: () -> Void

    /// Whether the Cc field is expanded. Starts open if the draft already
    /// carries a Cc (e.g. a reply seeded with correspondents) so the user
    /// isn't surprised by a hidden, already-populated field.
    @State private var isCcVisible: Bool

    /// True for the duration `justSentUndoJobID` is both non-nil AND still
    /// inside its undo hold — separate from the model's own `justSentUndoJobID`
    /// because the model has no notion of "hold elapsed" (`SendService`
    /// doesn't expose a countdown, only enqueue/cancel), so this view times
    /// its own visibility window locally, exactly like `ThreadView`'s local
    /// `toastText` auto-clear.
    @State private var isUndoToastVisible = false

    /// Feedback text for a non-functional placeholder tap (the AI Draft
    /// chip) — same local-toast pattern `ThreadView.showToast` uses for its
    /// own placeholders (Snooze, "⋯ more").
    @State private var placeholderToastText: String?

    public init(composer: ComposerModel, onClose: @escaping () -> Void) {
        self.composer = composer
        self.onClose = onClose
        self._isCcVisible = State(initialValue: !composer.cc.isEmpty)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let banner = composer.banner {
                Banner(text: banner, role: .warn)
            }
            header
            bodyEditor
            footer
        }
        // Approximates the Pencil frame's Compose Area (1100 total width −
        // 340 for the AI Draft panel this view doesn't render) scaled down
        // to a standalone modal footprint — a raw layout size, like
        // `CommandPaletteView`/`SearchView`'s own `.frame(width: 560)`, not
        // a design TOKEN (there's no `Metrics` entry for "modal width").
        .frame(width: 640, height: 560)
        .background(Palette.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                .strokeBorder(Palette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .overlay(alignment: .bottom) {
            bottomToast
                .padding(.bottom, Metrics.unit * 6)
        }
        .onChange(of: composer.justSentUndoJobID) {
            handleUndoJobIDChanged()
        }
    }

    // MARK: - Header (To / Cc / Subject)

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            toRow
            if isCcVisible {
                ccRow
            }
            subjectRow
        }
    }

    private var toRow: some View {
        HStack(spacing: Metrics.unit * 3) {
            fieldLabel("To")
            TextField("Recipients", text: toBinding)
                .textFieldStyle(.plain)
                .font(Typography.ui(13))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: Metrics.unit)
            // Only a Cc toggle — `ComposerModel` carries no `bcc` field (a
            // reply's Bcc, if any, rides along in the untouched threading
            // scaffold; new-compose never offers one), so there's nothing
            // for a "Bcc" toggle to reveal.
            Button(action: { isCcVisible.toggle() }) {
                Text("Cc")
                    .font(Typography.ui(12, .medium))
                    .foregroundStyle(Palette.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.unit * 5)
        .padding(.vertical, Metrics.unit * 3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    private var ccRow: some View {
        HStack(spacing: Metrics.unit * 3) {
            fieldLabel("Cc")
            TextField("", text: ccBinding)
                .textFieldStyle(.plain)
                .font(Typography.ui(13))
                .foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, Metrics.unit * 5)
        .padding(.vertical, Metrics.unit * 3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    private var subjectRow: some View {
        // No separate "Subject" label — the field's own placeholder reads
        // as one, matching a familiar mail-compose convention.
        TextField("Subject", text: subjectBinding)
            .textFieldStyle(.plain)
            .font(Typography.ui(13, .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Metrics.unit * 5)
            .padding(.vertical, Metrics.unit * 3)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.border).frame(height: 1)
            }
    }

    // A fixed-width leading label so To/Cc rows line up — derived from
    // `unit`, not a raw literal.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui(13))
            .foregroundStyle(Palette.inkTertiary)
            .frame(width: Metrics.unit * 10, alignment: .leading)
    }

    // MARK: - Body (serif editor)

    private var bodyEditor: some View {
        TextEditor(text: bodyTextBinding)
            .font(Typography.serif(15))
            .foregroundStyle(Palette.ink)
            .scrollContentBackground(.hidden)
            .background(Palette.bgSurface)
            .padding(.horizontal, Metrics.unit * 4)
            .padding(.vertical, Metrics.unit * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer (Send / Cancel / reply's AI Draft placeholder)

    private var footer: some View {
        HStack(spacing: Metrics.unit * 3) {
            PrimaryButton(title: "Send", action: { Task { await composer.send() } })
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(composer.isSending)
            QuietButton(title: "Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: Metrics.unit)
            if isReplyMode {
                draftPlaceholderChip
            }
        }
        .padding(.horizontal, Metrics.unit * 5)
        .padding(.vertical, Metrics.unit * 3)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.border).frame(height: 1)
        }
    }

    /// The AI "Draft in your voice" affordance from the Pencil design's
    /// right-hand panel — NON-FUNCTIONAL here (that panel's real streaming
    /// draft is a later milestone), so a tap only surfaces a toast, exactly
    /// matching `ThreadView.summaryChip`'s own "not built yet" placeholder
    /// convention (same `aiBg`/`aiInk` tokens, zero network egress).
    private var draftPlaceholderChip: some View {
        Button(action: { showPlaceholderToast("AI draft arrives in a later milestone") }) {
            Text("✦ Draft")
                .font(Typography.ui(12, .medium))
                .foregroundStyle(Palette.aiInk)
                .padding(.vertical, Metrics.unit * 2)
                .padding(.horizontal, Metrics.unit * 3)
                .background(Palette.aiBg)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
        .buttonStyle(.plain)
    }

    private var isReplyMode: Bool {
        if case .reply = composer.mode { return true }
        return false
    }

    // MARK: - Toasts (undo-send + placeholder feedback)

    /// Which toast (if either) sits above the footer right now. The undo
    /// toast takes priority — a just-sent draft's undo window is the more
    /// important thing on screen than a placeholder tap's feedback.
    @ViewBuilder
    private var bottomToast: some View {
        if isUndoToastVisible, composer.justSentUndoJobID != nil {
            undoToast
        } else if let placeholderToastText {
            Toast(text: placeholderToastText)
        }
    }

    /// Tapping the WHOLE toast undoes the send — `Toast` itself is a plain
    /// presentational `Text`, so the tap target is this wrapping `Button`,
    /// matching how `draftPlaceholderChip`/`ThreadView`'s chips wrap a
    /// styled body in a plain-style `Button`.
    private var undoToast: some View {
        Button(action: { Task { await composer.undo() } }) {
            Toast(text: "Sent · Undo")
        }
        .buttonStyle(.plain)
    }

    /// Mirrors a `send()` succeeding (`justSentUndoJobID` going non-nil) by
    /// opening the undo toast for the hold window, then auto-hiding it — a
    /// successful `undo()` also clears `justSentUndoJobID`, which re-fires
    /// this and hides the toast immediately via the `nil` branch below.
    private func handleUndoJobIDChanged() {
        guard composer.justSentUndoJobID != nil else {
            isUndoToastVisible = false
            return
        }
        isUndoToastVisible = true
        Task {
            try? await Task.sleep(for: Self.undoToastHoldWindow)
            isUndoToastVisible = false
        }
    }

    private func showPlaceholderToast(_ text: String) {
        placeholderToastText = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if placeholderToastText == text {
                placeholderToastText = nil
            }
        }
    }

    /// How long the undo toast stays up — mirrors `SendService.enqueue`'s
    /// own `undoHold` DEFAULT (`.seconds(15)`, `Sources/Outbox/
    /// SendService.swift`). `ComposerModel.send()` calls `enqueue` without
    /// overriding that default, so this constant and the real hold window
    /// are the same value; there's no shared symbol to import instead
    /// (`undoHold` is a parameter default, not a public constant).
    private static let undoToastHoldWindow: Duration = .seconds(15)

    // MARK: - Field bindings

    // Manual `Binding`s, matching `CommandPaletteView`/`SearchView`'s own
    // convention — keeps `ComposerModel` a plain `let` reference here rather
    // than adding an `@Bindable` just for four fields.
    private var toBinding: Binding<String> {
        Binding(get: { composer.to }, set: { composer.to = $0 })
    }

    private var ccBinding: Binding<String> {
        Binding(get: { composer.cc }, set: { composer.cc = $0 })
    }

    private var subjectBinding: Binding<String> {
        Binding(get: { composer.subject }, set: { composer.subject = $0 })
    }

    private var bodyTextBinding: Binding<String> {
        Binding(get: { composer.bodyText }, set: { composer.bodyText = $0 })
    }
}

#Preview {
    // `makeService: { nil }` — same test-safety reasoning as
    // `ComposerModelTests`: a Preview must never touch the real Keychain.
    let db = try! HudsonDatabase.inMemory()
    let model = ComposerModel(database: db, account: nil, makeService: { nil })
    model.startNew()
    model.to = "friend@example.com"
    model.subject = "Lunch?"
    return ComposerView(composer: model, onClose: {})
        .padding(40)
        .background(Palette.bgApp)
}
