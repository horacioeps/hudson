/// Case-insensitive subsequence fuzzy matcher for the ⌘K command palette.
///
/// `score` answers two questions at once: does `query` match `candidate` at
/// all (a `nil` result means no — every character of `query` must appear in
/// `candidate`, in order, though not necessarily adjacent), and, if so, how
/// good is the match (higher is better, for ranking results best-first).
public enum FuzzyMatch {

    // The four bonuses below are tiered by an order of magnitude each, so a
    // higher tier always outscores every possible accumulation from a lower
    // one (command titles here are well under 50 characters, nowhere near
    // enough matched letters for a lower tier to close a 4x-5x gap).

    /// Awarded when the FIRST matched character lines up with `candidate`'s
    /// very first character — the strongest signal available that the user
    /// is typing the start of the exact thing they want (e.g. "arch" typed
    /// for "Archive"). Ranked above every other bonus, so a true prefix
    /// match always sorts ahead of a mid-string match, however contiguous.
    private static let prefixBonus = 100

    /// Awarded when a matched character immediately follows a word
    /// boundary — a space — in `candidate`, since that's where a new word
    /// starts (e.g. "arch" matching the "Archive" inside "Move to Archive",
    /// right after the space). Ranked below a full prefix match but above
    /// plain contiguity.
    private static let boundaryBonus = 20

    /// Awarded when a matched character sits immediately after the
    /// PREVIOUS matched character, rewarding an unbroken run of letters
    /// (e.g. "arc" matching "arc" inside "arcade" as one run) over the same
    /// letters found scattered further apart in the candidate.
    private static let contiguousBonus = 5

    /// Awarded once per matched character, regardless of position — a
    /// tie-breaking floor that keeps a longer overlap between `query` and
    /// `candidate` from ever losing to a shorter one that merely happens to
    /// land a bigger positional bonus.
    private static let matchBonus = 1

    /// Scores `candidate` against `query`, or returns `nil` if `query`'s
    /// characters do not all appear in `candidate` in order (a
    /// case-insensitive subsequence test). An empty `query` is trivially a
    /// subsequence of everything and scores `0` for every candidate — the
    /// contract an empty palette search field relies on to show the full,
    /// unranked command list.
    ///
    /// Matching walks `candidate` once, left to right, greedily binding
    /// each `query` character to the EARLIEST available position. This is
    /// simple and fully deterministic, at the cost of not always finding
    /// the globally highest-scoring alignment for adversarial inputs;
    /// command-palette titles are short and this tradeoff is invisible in
    /// practice.
    public static func score(_ candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let candidateLetters = Array(candidate.lowercased())
        let queryLetters = Array(query.lowercased())

        var totalScore = 0
        var searchFrom = candidateLetters.startIndex
        var previousMatchIndex: Int?

        for queryLetter in queryLetters {
            guard searchFrom < candidateLetters.endIndex,
                let matchIndex = candidateLetters[searchFrom...].firstIndex(of: queryLetter)
            else {
                return nil
            }

            totalScore += matchBonus
            if matchIndex == 0 {
                totalScore += prefixBonus
            } else if candidateLetters[matchIndex - 1] == " " {
                totalScore += boundaryBonus
            }
            if previousMatchIndex.map({ matchIndex == $0 + 1 }) == true {
                totalScore += contiguousBonus
            }

            previousMatchIndex = matchIndex
            searchFrom = matchIndex + 1
        }

        return totalScore
    }
}
