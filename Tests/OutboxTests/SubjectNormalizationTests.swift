import Testing
@testable import Outbox

/// Table-driven coverage for `SubjectNormalization.replySubject` (spec
/// §7.1): a reply's Subject must carry exactly ONE normalized `Re: `
/// prefix, tolerating whatever the original already had — including
/// localized variants (`AW:` German, `SV:` Swedish) and repeats — so a long
/// reply chain never accumulates `Re: Re: Re: …`.
private let cases: [(original: String, expected: String)] = [
    ("Meeting notes", "Re: Meeting notes"),
    ("Re: Meeting notes", "Re: Meeting notes"),
    ("RE: Meeting notes", "Re: Meeting notes"),
    ("AW: Meeting notes", "Re: Meeting notes"),
    ("SV: Meeting notes", "Re: Meeting notes"),
    ("Re: Re: Meeting notes", "Re: Meeting notes"),
    ("re:meeting", "Re: meeting"),
    ("AW: RE: Meeting notes", "Re: Meeting notes"),
    ("  Meeting notes  ", "Re: Meeting notes"),
    ("Re:Re:Re: triple stack", "Re: triple stack"),
    // A subject that merely CONTAINS "re:" mid-string (not as a leading
    // prefix) must be left alone — only a LEADING prefix is stripped.
    ("Store: pre-order details", "Re: Store: pre-order details"),
]

@Test func replySubjectNormalizesEveryCase() {
    for (original, expected) in cases {
        #expect(
            SubjectNormalization.replySubject(from: original) == expected,
            "input: \(original)")
    }
}

@Test func replySubjectOfEmptyStringIsJustThePrefix() {
    #expect(SubjectNormalization.replySubject(from: "") == "Re: ")
}
