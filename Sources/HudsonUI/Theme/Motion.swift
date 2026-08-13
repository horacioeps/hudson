import AppKit
import SwiftUI

/// Hudson's motion tokens. Views reference `Motion.expand`, never a literal
/// `.spring(response:)` — so the whole app's feel is re-tuned from one place,
/// exactly as `Palette` and `Metrics` centralize color and spacing.
///
/// Two rules govern every value below. First, tempo: this is a tool people keep
/// open all day, so motion exists to explain a state change, not to be noticed.
/// Nothing here runs longer than 280ms and most things land inside 180ms —
/// past roughly a quarter-second a transition stops reading as feedback and
/// starts reading as latency. Second, curve choice: anything that MOVES or
/// RESIZES gets a spring, because a spring's settle is what makes an object
/// feel like it has a size and a destination; anything that is purely a
/// cross-fade gets an ease, because opacity has no mass and a bouncing color
/// reads as a toy. Exits are always faster and flatter than entrances —
/// arriving should feel placed, dismissing should feel instant.
///
/// `@MainActor`-isolated for the same reason as `Typography`: every caller is a
/// SwiftUI `View` body, and `reduceMotion` reads AppKit state.
@MainActor
public enum Motion {
    // MARK: - Reduce Motion

    /// Live read of the OS setting, never cached — a user can toggle Reduce
    /// Motion from System Settings while Hudson is open, and the next frame
    /// should honor it. The lookup is a cached defaults read, so it is cheap
    /// enough to sit on the animation path.
    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Tempo

    /// Press feedback and other acknowledgements that must beat the eye.
    public static let instant: TimeInterval = 0.08
    /// Cross-fades and hover-ins: present, but never something you wait on.
    public static let quick: TimeInterval = 0.12
    /// The default beat — height settles, banners, reveals.
    public static let standard: TimeInterval = 0.18
    /// Reserved for arrivals that carry weight (overlay entry, toast in).
    public static let deliberate: TimeInterval = 0.24

    // MARK: - Spatial curves (things that move or resize)

    /// The signature gesture: a message card opening, a disclosure revealing
    /// its content. Damping 0.86 settles without visible overshoot — an inbox
    /// that bounces is an inbox that looks unserious.
    public static var expand: Animation? { spatial(.spring(response: 0.28, dampingFraction: 0.86)) }

    /// The reverse. Deliberately shorter and eased, not sprung: closing is a
    /// dismissal, and a dismissal that overshoots looks reluctant.
    public static var collapse: Animation? { spatial(.easeOut(duration: standard)) }

    /// Selection chrome moving between rows or tabs (`matchedGeometryEffect`).
    /// Fast, because j/k auto-repeats: at 0.20s a held key reads as one
    /// continuous slide rather than a queue of hops piling up behind the input.
    public static var travel: Animation? { spatial(.spring(response: 0.20, dampingFraction: 0.86)) }

    /// A modal or toast arriving. The one place a trace of spring is welcome —
    /// it is what makes a card feel placed rather than pasted.
    ///
    /// The one spatial token whose Reduce Motion fallback is a curve rather
    /// than `nil`: every call site uses it ONLY to drive a transition
    /// (`overlayCard`, `toast`), and those have already degraded themselves to
    /// a plain `.opacity` by then — so nothing here moves under the setting,
    /// while `nil` would suppress the transition altogether and snap a
    /// full-window modal into place between two frames.
    public static var present: Animation? {
        reduceMotion ? crossfade : .spring(response: 0.28, dampingFraction: 0.88)
    }

    /// A modal or toast leaving. Ease, not spring, and half the duration of
    /// `present`: the user has already decided, so get out of the way.
    public static var dismiss: Animation { .easeIn(duration: quick) }

    /// A container settling to a new natural height after user-driven content
    /// changed — quoted history, a banner, the summary chip's final wrap.
    public static var settle: Animation? { spatial(.easeOut(duration: standard)) }

    /// Pulling a keyboard-selected row just inside the viewport. Short enough
    /// that holding a key never queues scrolls behind the selection.
    public static var scrollFollow: Animation? { spatial(.easeOut(duration: 0.14)) }

    // MARK: - Opacity curves (nothing moves)

    /// Swapping one piece of content for another in place: status text, a
    /// snippet giving way to a body, a label changing its word.
    public static let crossfade: Animation = .easeOut(duration: quick)

    /// Hover-in. Paired with `hoverOut`, which is slower on purpose: a pointer
    /// sweeping down a list would otherwise leave a trail of rows lit at once.
    public static let hoverIn: Animation = .easeOut(duration: 0.10)
    public static let hoverOut: Animation = .easeIn(duration: 0.16)

    /// Mouse-down acknowledgement. Press feedback that eases IN feels laggy, so
    /// this is the shortest token in the file; the release rides `hoverOut`.
    public static let press: Animation = .easeOut(duration: instant)

    // MARK: - Transitions

    /// Content unfolding from beneath the control that owns it — a message
    /// body, a quoted block, a note under the summary chip. The 6pt offset is
    /// small by design: it should read as the text settling into space the
    /// container already opened, not as a drawer sliding.
    public static var reveal: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)),
            removal: .opacity)
    }

    /// A centered modal card. Scale only — never a vertical slide, which reads
    /// as an iOS sheet rather than a Mac palette. Kept to 0.96–1.0 because
    /// scaling rasterizes any `NSTextView`-backed subtree for the duration.
    public static var overlayCard: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.96).combined(with: .opacity),
            removal: .scale(scale: 0.98).combined(with: .opacity))
    }

    /// A toast rising into its resting position. It leaves by fading in place:
    /// sliding away would claim the user dismissed it, when in truth its window
    /// simply expired.
    public static var toast: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 10).combined(with: .opacity),
            removal: .opacity)
    }

    /// A banner dropping in over the top of the shell. Safe as a `.move` only
    /// because banners overlay rather than displace the panes beneath them.
    public static var banner: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity)
    }

    // MARK: -

    /// Removes a spatial animation outright when the user has asked the OS for
    /// less motion: `nil` lands the property in the next frame instead of
    /// interpolating it. Softening the curve is not enough and never was — an
    /// `.offset`, a `matchedGeometryEffect` or a `scaleEffect` still travels
    /// its whole distance under a faster ease, which is exactly the sensation
    /// the setting exists to remove. Legibility does not go with it: anything
    /// that has to stay readable across a change is a cross-fade already
    /// (`crossfade`, `press`, the hover pair), and the transitions above
    /// degrade to `.opacity` on their own.
    ///
    /// A property whose motion is inherent to the property rather than to its
    /// animation — `PressableButtonStyle`'s 3% press scale is the only one —
    /// has to drop the movement at its own call site; no `Animation` value can
    /// do it from here.
    private static func spatial(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
