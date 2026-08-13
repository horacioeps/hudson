import SwiftUI

/// The ⌘K command palette: a centered modal with a search field and a
/// keyboard-navigable list of `Command`s. Binds directly to a `CommandModel`
/// for `query`/`results`; `perform` and `onClose` are supplied by the host
/// (`AppModel`, via `RootView`) so this view owns no command DISPATCH logic
/// itself — matches `CommandModel`'s own doc comment on why interpreting a
/// `Command`'s `kind` deliberately lives outside the model.
public struct CommandPaletteView: View {
    private let command: CommandModel
    private let perform: (Command) -> Void
    private let onClose: () -> Void

    @FocusState private var isQueryFieldFocused: Bool

    public init(
        command: CommandModel, perform: @escaping (Command) -> Void, onClose: @escaping () -> Void
    ) {
        self.command = command
        self.perform = perform
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            queryField
            // The card's height is a hard cut, deliberately — no transition on
            // the list and no animation on the container. `RootView` centres
            // this modal in a ZStack, so half of any height change is spent
            // moving the query field the user is typing into: collapsing to
            // the field alone would slide it ~140pt down the screen mid-word,
            // and back up on the next character that matches. `SearchView`'s
            // twin 560pt card swaps its results the same way for the same
            // reason.
            if !command.results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Palette.border).frame(height: 1)
                    resultsList
                }
            }
        }
        // 560 is the Pencil spec width for the palette, not derived from `unit`.
        .frame(width: 560)
        .background(Palette.bgSunken)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                .strokeBorder(Palette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear { isQueryFieldFocused = true }
        // These `.onKeyPress` handlers are a fallback for this view hosted
        // standalone (a Preview, a future isolated test) — under the real
        // app, `RootView`'s global `KeyboardMonitor` is the SOLE authority
        // for Up/Down/Return/Esc while the palette is visible (see
        // `KeyRouter`'s doc comment on why `.onKeyPress` bubbling past a
        // focused `TextField` is too fragile to rely on): the monitor
        // consumes those key-downs before AppKit ever dispatches them into
        // SwiftUI, so these handlers simply never fire in that path.
        .onKeyPress(.downArrow) {
            command.moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            command.moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            performHighlighted()
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var queryField: some View {
        TextField("Type a command…", text: queryBinding)
            .textFieldStyle(.plain)
            .font(Typography.ui(15))
            .foregroundStyle(Palette.ink)
            .focused($isQueryFieldFocused)
            .padding(.horizontal, Metrics.unit * 4)
            .padding(.vertical, Metrics.unit * 4)
            .onChange(of: command.query) {
                command.filter()  // resets `command.highlightedIndex` to 0 itself
            }
    }

    /// A manual `Binding` (rather than `@Bindable`) so `CommandModel` stays
    /// a plain `let` reference here — matches `InboxListView`/
    /// `SidebarView`'s existing convention of mutating a model's
    /// `@Observable` properties directly from a view action, without a
    /// binding property wrapper on the model reference itself.
    private var queryBinding: Binding<String> {
        Binding(get: { command.query }, set: { command.query = $0 })
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(command.results.enumerated()), id: \.element.id) { index, entry in
                        row(for: entry, isHighlighted: index == command.clampedHighlightedIndex)
                    }
                }
            }
            // Without this, arrowing past the 360pt cap moves an invisible
            // highlight while the list sits still. No anchor: SwiftUI then
            // scrolls the minimum distance needed to reveal the row, which is
            // the right behavior in BOTH directions — pinning to `.bottom`
            // would yank the list on every upward step.
            .onChange(of: command.clampedHighlightedIndex) { _, index in
                guard command.results.indices.contains(index) else { return }
                withAnimation(Motion.scrollFollow) { proxy.scrollTo(command.results[index].id) }
            }
        }
        // Caps the list so a long result set scrolls within the modal
        // rather than growing the window past a reasonable height.
        .frame(maxHeight: 360)
    }

    private func row(for entry: Command, isHighlighted: Bool) -> some View {
        Button(action: { perform(entry) }) {
            HStack(spacing: Metrics.unit * 3) {
                Image(systemName: Self.icon(for: entry.kind))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: Metrics.unit * 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(Typography.ui(13, .medium))
                        .foregroundStyle(Palette.ink)
                    if let subtitle = entry.subtitle {
                        Text(subtitle)
                            .font(Typography.ui(11))
                            .foregroundStyle(Palette.inkTertiary)
                    }
                }
                Spacer(minLength: Metrics.unit)
                HStack(spacing: 2) {
                    ForEach(entry.keys, id: \.self) { key in
                        Keycap(key)
                    }
                }
            }
            .padding(.horizontal, Metrics.unit * 4)
            .padding(.vertical, Metrics.unit * 2)
        }
        .buttonStyle(OverlayRowStyle(isHighlighted: isHighlighted))
    }

    // MARK: - Keyboard navigation

    /// Fallback for the standalone `.onKeyPress(.return)` above — see its
    /// comment. Performing itself is dispatched by the caller-supplied
    /// `perform` closure (matches `row(for:isHighlighted:)`'s own Button
    /// action), never by `CommandModel` — see `CommandKind`'s doc comment
    /// on why command dispatch deliberately lives outside the model.
    private func performHighlighted() {
        guard let highlighted = command.highlightedCommand else { return }
        perform(highlighted)
    }

    /// A representative SF Symbol per `CommandKind` — purely decorative;
    /// `Command` itself carries no icon of its own.
    private static func icon(for kind: CommandKind) -> String {
        switch kind {
        case .archive: return "archivebox"
        case .toggleStar: return "star"
        case .toggleRead: return "envelope.badge"
        case .snooze: return "clock"
        case .moveToSplit: return "arrow.right.square"
        case .openSearch: return "magnifyingglass"
        case .switchSplit: return "tray"
        }
    }
}

/// The row affordance shared by both overlay lists — the palette's commands
/// and `SearchView`'s hits. It lives here rather than in `Components/` because
/// those two views are its only callers; a third would earn it a file.
///
/// It exists because `.buttonStyle(.plain)` gives a macOS row neither a hover
/// nor a pressed state, so without it clicking a row is acknowledged only by
/// the overlay vanishing. Hover and keyboard highlight deliberately use
/// DIFFERENT tokens (`bgHover` vs `bgSelected`): when both are on screen they
/// have to read as two different things — where the mouse is, and what Return
/// will fire. For the same reason hovering must never write
/// `CommandModel.highlightedIndex`, or a resting pointer would silently
/// retarget the keyboard.
struct OverlayRowStyle: ButtonStyle {
    /// Whether the keyboard highlight is on this row. Always `false` for
    /// search hits, which have no keyboard navigation.
    var isHighlighted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, isHighlighted: isHighlighted)
    }

    /// A real `View` rather than an inline body so it can hold the `@State`
    /// hover flag, which `makeBody` itself cannot.
    private struct Row: View {
        let configuration: Configuration
        let isHighlighted: Bool

        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(fill)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                // Three animations, each scoped to the one flag that drives it,
                // so a hover never animates the keyboard highlight and vice
                // versa. Press lands almost instantly and releases on the
                // slower `hoverOut`: acknowledgement that eases IN feels laggy.
                .animation(configuration.isPressed ? Motion.press : Motion.hoverOut,
                           value: configuration.isPressed)
                .animation(isHovering ? Motion.hoverIn : Motion.hoverOut, value: isHovering)
                .animation(Motion.crossfade, value: isHighlighted)
        }

        private var fill: Color {
            if configuration.isPressed || isHighlighted { return Palette.bgSelected }
            return isHovering ? Palette.bgHover : .clear
        }
    }
}

#Preview {
    let command = CommandModel()
    command.reload(
        splits: [SplitTab(key: "primary", title: "Primary", count: 12)], hasSelection: true)
    return CommandPaletteView(command: command, perform: { _ in }, onClose: {})
        .padding(40)
        .background(Palette.bgApp)
}
