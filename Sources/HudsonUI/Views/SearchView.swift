import Store
import SwiftUI

/// The search overlay: a query field with a scope toggle (All / Inbox) and
/// a list of `SearchHit` results. Binds directly to a `SearchModel` for
/// `query`/`scope`/`hits`/`isSearching` — debounce, cancellation, and the
/// 2-char floor already live inside that model (see its doc comment); this
/// view only ever calls `queryChanged()` right after an edit. `onOpen` is
/// supplied by the host so this view owns no navigation state itself.
public struct SearchView: View {
    private let search: SearchModel
    private let onOpen: (String) -> Void

    @FocusState private var isQueryFieldFocused: Bool
    @Namespace private var scopeNamespace

    public init(search: SearchModel, onOpen: @escaping (String) -> Void) {
        self.search = search
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            queryField
            scopeToggle
            Rectangle().fill(Palette.border).frame(height: 1)
            resultsArea
        }
        // 560 matches `CommandPaletteView`'s width — the Pencil spec keeps
        // both overlay modals the same size, not derived from `unit`.
        .frame(width: 560)
        .background(Palette.bgSunken)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                .strokeBorder(Palette.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        .onAppear { isQueryFieldFocused = true }
    }

    private var queryField: some View {
        HStack(spacing: Metrics.unit * 2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.inkTertiary)
            TextField("Search mail…", text: queryBinding)
                .textFieldStyle(.plain)
                .font(Typography.ui(15))
                .foregroundStyle(Palette.ink)
                .focused($isQueryFieldFocused)
                .onChange(of: search.query) {
                    search.queryChanged()
                }
            // The slot is reserved whether or not a search is in flight: the
            // spinner is a sibling of the field, so letting it claim width on
            // appearance reflows the field on nearly every keystroke at a
            // 150ms debounce.
            ZStack {
                if search.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .transition(Motion.reveal)
                }
            }
            .frame(width: Metrics.unit * 4)
            // Delayed on the way in so a search that resolves faster than the
            // eye never shows a spinner at all; immediate on the way out,
            // because a spinner still turning after results have landed is a
            // lie about what the app is doing.
            .animation(
                search.isSearching ? Motion.crossfade.delay(Motion.deliberate) : Motion.crossfade,
                value: search.isSearching)
        }
        .padding(.horizontal, Metrics.unit * 4)
        .padding(.vertical, Metrics.unit * 4)
    }

    /// Manual `Binding`, matching `CommandPaletteView.queryBinding` — see
    /// that doc comment for why `SearchModel` stays a plain `let` here.
    private var queryBinding: Binding<String> {
        Binding(get: { search.query }, set: { search.query = $0 })
    }

    private var scopeToggle: some View {
        HStack(spacing: Metrics.unit * 2) {
            scopeButton(title: "All", scope: .all)
            scopeButton(title: "Inbox", scope: .inbox)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.unit * 4)
        .padding(.bottom, Metrics.unit * 3)
        // Keyed on the scope alone, never on the re-search it kicks off: the
        // results underneath cannot land for at least the model's 150ms
        // debounce, and the toggle has to feel resolved long before they do.
        .animation(Motion.travel, value: isScope(.all))
    }

    private func scopeButton(title: String, scope: SearchScope) -> some View {
        let isActive = isScope(scope)
        return Button(action: {
            search.scope = scope
            search.queryChanged()
        }) {
            Text(title)
                .font(Typography.ui(12, .semibold))
                .foregroundStyle(isActive ? Palette.ink : Palette.inkTertiary)
                .padding(.vertical, Metrics.unit)
                .padding(.horizontal, Metrics.unit * 3)
                // One pill, handed between the two buttons, so it slides and
                // resizes instead of blinking across. `matchedGeometryEffect`
                // is unambiguously safe here and nowhere else on this surface:
                // both buttons are always mounted and never lazy, so the pill
                // can't be orphaned by a de-materialized source.
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                            .fill(Palette.accentSoft)
                            .matchedGeometryEffect(id: "scopePill", in: scopeNamespace)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// `SearchScope` isn't `Equatable` — compares by case directly rather
    /// than adding a conformance just for this toggle's highlight state.
    private func isScope(_ scope: SearchScope) -> Bool {
        switch (search.scope, scope) {
        case (.all, .all), (.inbox, .inbox): return true
        default: return false
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if search.hits.isEmpty {
            emptyState
        } else {
            resultsList
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Text(emptyStateText)
                .font(Typography.ui(13))
                .foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var emptyStateText: String {
        if search.isSearching { return "Searching…" }
        return search.query.isEmpty ? "Search your mail" : "No results"
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(search.hits, id: \.messageID) { hit in
                    row(for: hit)
                    Rectangle().fill(Palette.border).frame(height: 1)
                }
            }
        }
        // Caps the list so a long result set scrolls within the modal
        // rather than growing the window past a reasonable height.
        .frame(maxHeight: 420)
    }

    private func row(for hit: SearchHit) -> some View {
        Button(action: { onOpen(hit.threadID) }) {
            VStack(alignment: .leading, spacing: Metrics.unit) {
                HStack {
                    Text(hit.subject)
                        .font(Typography.ui(13, .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: Metrics.unit)
                    Text(InboxListView.formattedTime(epochMilliseconds: hit.internalDate))
                        .font(Typography.ui(11))
                        .foregroundStyle(Palette.inkTertiary)
                }
                Text(SenderInfo.name(fromLine: hit.fromLine))
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                Text(HTMLEntities.decode(hit.snippet))
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Metrics.unit * 4)
            .padding(.vertical, Metrics.unit * 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Hover and press only — `isHighlighted` stays false because search
        // hits have no keyboard navigation to reflect.
        .buttonStyle(OverlayRowStyle())
    }
}

#Preview {
    // Unseeded — no query has been typed, so this renders the "Search your
    // mail" empty state. The render smoke test exercises real seeded hits
    // instead (see `RenderSmokeTests.searchViewRendersWithSeededHits`).
    let db = try! HudsonDatabase.inMemory()
    let model = SearchModel(database: db, account: "you@hudson.app")
    return SearchView(search: model, onOpen: { _ in })
        .padding(40)
        .background(Palette.bgApp)
}
