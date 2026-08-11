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
            if !command.results.isEmpty {
                Rectangle().fill(Palette.border).frame(height: 1)
                resultsList
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
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(command.results.enumerated()), id: \.element.id) { index, entry in
                    row(for: entry, isHighlighted: index == command.clampedHighlightedIndex)
                }
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
            .background(isHighlighted ? Palette.bgSelected : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

#Preview {
    let command = CommandModel()
    command.reload(
        splits: [SplitTab(key: "primary", title: "Primary", count: 12)], hasSelection: true)
    return CommandPaletteView(command: command, perform: { _ in }, onClose: {})
        .padding(40)
        .background(Palette.bgApp)
}
