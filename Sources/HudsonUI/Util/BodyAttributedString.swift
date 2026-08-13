import Foundation
import SwiftUI

/// Maps parsed `BodySpan`s onto Hudson's real fonts and colors.
///
/// This is the ONLY place the native body path chooses type, and it is
/// deliberately the thin end of the work: `MessageBodyParser` did the parsing
/// and quote splitting as pure, non-isolated logic, leaving this step with
/// nothing to decide except which `Typography` face a semantic flag maps to.
/// `@MainActor` because `Typography.register()` is.
@MainActor
enum BodyAttributedString {
    /// Message prose, per the Pencil "Thread (Expanded)" frame: `$font-ui` at
    /// 14 with a 1.55 line height.
    ///
    /// Body copy is SANS, not the Newsreader serif this used to use. Across
    /// the whole design file, `$font-serif` appears 7 times against 484 uses
    /// of `$font-ui`, and every one of those seven is the "Hudson" wordmark,
    /// the type specimen, or a marketing line. Newsreader is a display face;
    /// the reading pane had drifted into using it for body text.
    static let bodySize: CGFloat = 14
    static let bodyLineSpacing: CGFloat = bodySize * 0.55

    static func make(_ spans: [BodySpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var piece = AttributedString(span.text)
            piece.font = font(for: span)
            // A link gets the accent treatment; everything else is body ink.
            // Sender colors were discarded at parse time and can't reach here.
            piece.foregroundColor = span.link == nil ? Palette.ink : Palette.accent
            if let link = span.link { piece.link = link }
            if span.underline || span.link != nil {
                piece.underlineStyle = .single
            }
            result.append(piece)
        }
        return result
    }

    /// `italic` has no `Font.Weight` equivalent, so it comes off the resolved
    /// font rather than the weight argument.
    private static func font(for span: BodySpan) -> Font {
        let weight: Font.Weight = span.bold ? .semibold : .regular
        let base: Font = span.monospace
            ? .system(size: bodySize, weight: weight, design: .monospaced)
            : Typography.ui(bodySize, weight)
        return span.italic ? base.italic() : base
    }
}
