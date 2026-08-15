import Foundation

/// Layout constants lifted verbatim from the Pencil Design System frame.
/// Every atom derives its spacing from `unit` rather than hard-coding
/// point values, so the whole app's rhythm can be re-tuned from one place.
public enum Metrics {
    /// Base spacing unit; padding and gaps are multiples of this.
    public static let unit: CGFloat = 4.0

    public static let radiusLarge: CGFloat = 12.0
    public static let radiusMedium: CGFloat = 7.0
    public static let radiusSmall: CGFloat = 4.0

    public static let sidebarWidth: CGFloat = 224.0
    public static let listWidth: CGFloat = 384.0

    /// Height of the sidebar footer's mail-download bar (`ProgressTrack`).
    /// Sub-`unit` on purpose: this is background chrome that appears on first
    /// launch and then effectively never again, so it reads as a hairline
    /// under the status text rather than as a control competing with it.
    public static let progressTrackHeight: CGFloat = 3.0
}
