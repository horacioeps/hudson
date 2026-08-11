import Foundation

/// Reply-subject normalization (spec §7.1). Threading requires the FULL
/// triple — Gmail `threadId` + `References`/`In-Reply-To` + a MATCHING
/// Subject — and the Subject leg specifically must collapse to exactly one
/// `Re: ` prefix no matter how many hops deep the reply chain is, or how
/// the previous client localized its own prefix (German `AW:`, Swedish
/// `SV:`). Without collapsing, a long thread's Subject would grow
/// `Re: Re: Re: …` forever and — worse — a client that normalizes
/// differently than the one before it would produce a Subject that no
/// longer matches, silently breaking the threading triple.
public enum SubjectNormalization {
    /// Strips a leading `Re:`/`RE:`/`AW:`/`SV:` prefix, repeated any number
    /// of times and however it was spaced, then applies exactly one
    /// normalized `Re: ` prefix.
    private static let leadingReplyPrefix = try! NSRegularExpression(
        pattern: #"^\s*(re|aw|sv)\s*:\s*"#, options: [.caseInsensitive])

    public static func replySubject(from original: String) -> String {
        var subject = original
        while let match = leadingReplyPrefix.firstMatch(
            in: subject, range: NSRange(subject.startIndex..., in: subject)
        ), let range = Range(match.range, in: subject) {
            subject.removeSubrange(range)
        }
        return "Re: \(subject.trimmingCharacters(in: .whitespaces))"
    }
}
