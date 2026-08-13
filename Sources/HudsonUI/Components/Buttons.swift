import AppKit
import SwiftUI

/// Mouse-down acknowledgement for every button Hudson draws itself. Scale
/// only — no fill change — because it has to read correctly on a bare gear
/// glyph as well as on a filled pill, and a tint overlay would need each
/// caller's clip shape to avoid painting a rectangle around an icon. Under
/// Reduce Motion it is a dim instead; see `makeBody`.
///
/// Replaces `.buttonStyle(.plain)`: `.plain` also suppresses AppKit's bezel,
/// so nothing is lost by swapping to this.
public struct PressableButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Under Reduce Motion the scale is dropped, not merely sped up: a
            // 3% shrink is genuine movement, and no `Motion` token can take it
            // away from here (see `Motion.spatial`). This is the most
            // frequently fired animation in the app, so it also can't just
            // become nothing — a press still has to be acknowledged, and a dim
            // acknowledges it without anything moving.
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && Motion.reduceMotion ? 0.7 : 1)
            // Down is the shortest token in the file so the click never feels
            // reported-after-the-fact; the release gets the spring, which is
            // what makes the button read as a physical thing letting go.
            .animation(configuration.isPressed ? Motion.press : Motion.expand,
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    /// Reads at the call site exactly like the `.plain` it replaces.
    public static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

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
                // Asymmetric on purpose: a slower exit is what stops a pointer
                // sweeping across a row of buttons from strobing behind it.
                .animation(isHovering ? Motion.hoverIn : Motion.hoverOut, value: isHovering)
        }
        .buttonStyle(.pressable)
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
                .animation(isHovering ? Motion.hoverIn : Motion.hoverOut, value: isHovering)
        }
        .buttonStyle(.pressable)
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
