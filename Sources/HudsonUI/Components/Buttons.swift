import AppKit
import SwiftUI

/// The filled, high-emphasis button — Gmail's "Send", "Sync now", etc. Fill
/// is `accent`; hover darkens the fill ~6% (a standard affordance cue) rather
/// than swapping to a second accent token.
public struct PrimaryButton: View {
    private let title: String
    private let action: () -> Void
    @State private var isHovering = false

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(13, .semibold))
                .foregroundStyle(Palette.accentInk)
                // 6×12 padding is the Pencil spec value, not derived from `unit`.
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(isHovering ? Palette.accent.darkened(by: 0.06) : Palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The low-emphasis button — "Cancel", toolbar actions. Transparent at rest;
/// `bgHover` on hover is the only affordance, so it never competes visually
/// with a `PrimaryButton` on the same row.
public struct QuietButton: View {
    private let title: String
    private let action: () -> Void
    @State private var isHovering = false

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.ui(13, .semibold))
                .foregroundStyle(Palette.ink)
                // Same metrics as PrimaryButton, per spec.
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(isHovering ? Palette.bgHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension Color {
    /// Scales each RGB channel toward black by `fraction` (0.06 = 6% darker).
    /// Used only for the `PrimaryButton` hover state — everywhere else a view
    /// should reference a `Palette` token directly, never a derived color.
    func darkened(by fraction: Double) -> Color {
        let resolved = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        return Color(
            red: resolved.redComponent * (1 - fraction),
            green: resolved.greenComponent * (1 - fraction),
            blue: resolved.blueComponent * (1 - fraction),
            opacity: resolved.alphaComponent)
    }
}

#Preview {
    HStack {
        PrimaryButton(title: "Sync now", action: {})
        QuietButton(title: "Cancel", action: {})
    }
    .padding()
    .background(Palette.bgApp)
}
