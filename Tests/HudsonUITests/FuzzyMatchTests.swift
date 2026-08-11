import Testing
@testable import HudsonUI

/// `arc` and `ave` are both in-order subsequences of "archive"'s letters
/// (a-r-c-h-i-v-e); `xyz` shares no such ordering, so it isn't.
@Test func subsequenceCharactersMatchButNonSubsequenceDoesNot() {
    #expect(FuzzyMatch.score("archive", query: "arc") != nil)
    #expect(FuzzyMatch.score("archive", query: "ave") != nil)
    #expect(FuzzyMatch.score("archive", query: "xyz") == nil)
}

/// A candidate where `query` lines up with character 0 ("Archive") must
/// outrank one where the same letters only appear mid-string ("Move to
/// Archive") — the palette should put the more literal match first.
@Test func prefixMatchRanksAboveMidStringMatch() throws {
    let prefixScore = try #require(FuzzyMatch.score("Archive", query: "arch"))
    let midStringScore = try #require(FuzzyMatch.score("Move to Archive", query: "arch"))
    #expect(prefixScore > midStringScore)
}

/// An empty query is a subsequence of everything, so every candidate — even
/// an empty one — scores (at 0, per the documented contract), which is what
/// lets an empty palette search field show the full command list.
@Test func emptyQueryScoresEveryCandidateAtZero() {
    #expect(FuzzyMatch.score("archive", query: "") == 0)
    #expect(FuzzyMatch.score("", query: "") == 0)
    #expect(FuzzyMatch.score("anything at all", query: "") == 0)
}

/// Matching ignores case in both directions.
@Test func matchingIsCaseInsensitive() {
    #expect(FuzzyMatch.score("Archive", query: "ARCH") != nil)
    #expect(FuzzyMatch.score("ARCHIVE", query: "arch") != nil)
}

/// Isolates the word-boundary bonus: `b` matches "bar" right after a space
/// in "foo bar" but mid-word (no preceding space) in "foobar" — same
/// candidate length, same single matched character, only the boundary
/// differs.
@Test func wordBoundaryMatchRanksAboveNonBoundaryMatch() throws {
    let boundaryScore = try #require(FuzzyMatch.score("foo bar", query: "b"))
    let nonBoundaryScore = try #require(FuzzyMatch.score("fboo ar", query: "b"))
    #expect(boundaryScore > nonBoundaryScore)
}

/// Isolates the contiguity bonus: "arc" matches "arcade" as one unbroken
/// run right after the shared prefix bonus, but only as three scattered
/// letters in "a-r-cade" — same match count, same leading prefix bonus,
/// only the gaps differ.
@Test func contiguousRunRanksAboveScatteredSubsequence() throws {
    let contiguousScore = try #require(FuzzyMatch.score("arcade", query: "arc"))
    let scatteredScore = try #require(FuzzyMatch.score("a-r-cade", query: "arc"))
    #expect(contiguousScore > scatteredScore)
}
