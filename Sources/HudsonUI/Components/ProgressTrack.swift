import SwiftUI

/// A thin determinate progress bar for the first-launch mail download.
///
/// Deliberately NOT `SwiftUI.ProgressView`: its macOS style brings its own
/// accent color, corner radius, height and — for the indeterminate case — a
/// perpetual animation, none of which are expressible in Hudson's tokens. This
/// is a track and a fill, sized and colored from `Metrics`/`Palette` like every
/// other atom in the app.
///
/// **A nil `fraction` renders an EMPTY TRACK, never a fake.** There are two
/// moments where the total genuinely isn't known — before Gmail's first list
/// page returns, and on a run that is re-listing mail already on disk — and in
/// both the honest thing is a quiet empty slot beside a status line, not a
/// shimmer implying motion we can't measure. That choice is also why this file
/// needs no `.repeatForever` and no new Motion token: an indeterminate sweep
/// would have required both, plus an explicit carve-out from the 280ms budget
/// that every other animation in the app respects.
struct ProgressTrack: View {
    /// `0...1`, already ratcheted and capped by `AppModel`. `nil` means the
    /// total is unknown — see the type doc.
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.bgSunken)
                if let fraction {
                    Capsule()
                        .fill(Palette.accent)
                        // Clamped defensively as well as in the model: this
                        // view is also reachable from previews and the render
                        // smoke test, and a fraction outside 0...1 would draw
                        // a fill wider than its track.
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
        }
        .frame(height: Metrics.progressTrackHeight)
        // The fill RESIZES, so this is a spatial curve — which also means it
        // correctly becomes `nil` under Reduce Motion and the bar simply jumps
        // to each new value instead of sliding.
        .animation(Motion.settle, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Downloading mail")
        .accessibilityValue(
            fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Estimating")
    }
}

#Preview {
    VStack(spacing: Metrics.unit * 4) {
        ProgressTrack(fraction: nil)
        ProgressTrack(fraction: 0.27)
        ProgressTrack(fraction: 0.95)
        ProgressTrack(fraction: 1.0)
    }
    .padding(Metrics.unit * 6)
    .frame(width: 200)
    .background(Palette.bgApp)
}
