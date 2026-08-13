import Foundation
import Testing
@testable import HudsonUI

private func recipients(_ toLine: String, account: String = "you@hudson.app") -> String {
    MessageHeaderText.recipientLine(toLine: toLine, internalDate: 1_000, account: account)
}

// MARK: - Recipient line ("to you, David · <time>")

@Test func theAccountOwnerIsRenderedAsYou() {
    #expect(recipients("you@hudson.app").hasPrefix("to you ·"))
}

@Test func theAccountMatchIsCaseInsensitive() {
    #expect(recipients("You@Hudson.App").hasPrefix("to you ·"))
}

@Test func displayNamesArePreferredOverAddresses() {
    #expect(
        recipients("Sarah Lin <sarah@x.example>, you@hudson.app")
            .hasPrefix("to Sarah Lin, you ·"))
}

@Test func aBareAddressFallsBackToItsLocalPart() {
    // The full address would blow out a line that sits beside the sender name.
    #expect(recipients("david.okafor@northwind.example").hasPrefix("to david.okafor ·"))
}

@Test func moreThanTwoRecipientsCollapseToACount() {
    #expect(
        recipients("A One <a@x.example>, B Two <b@x.example>, C Three <c@x.example>")
            .hasPrefix("to A One, B Two +1 ·"))
}

@Test func anEmptyToHeaderLeavesJustTheTime() {
    let line = recipients("")
    #expect(!line.contains("to "))
    #expect(!line.isEmpty)
}

// MARK: - Avatar initials

@Test func initialsUseFirstAndLastNameLetters() {
    #expect(SenderInfo.initials(fromLine: "Sarah Lin <sarah@x.example>") == "SL")
    #expect(SenderInfo.initials(fromLine: "David Okafor <d@x.example>") == "DO")
}

@Test func aSingleWordNameUsesItsFirstTwoLetters() {
    // Never a lone glyph sitting next to two-letter neighbours.
    #expect(SenderInfo.initials(fromLine: "Slashy <info@slashy.example>") == "SL")
}

@Test func aDottedAddressWithNoDisplayNameStillYieldsTwoInitials() {
    #expect(SenderInfo.initials(fromLine: "derek.osei@brightleaf.example") == "DO")
}

@Test func initialsNeverCrashOnAMalformedHeader() {
    for line in ["", "   ", "<>", "<@>", "\"\" <>"] {
        #expect(!SenderInfo.initials(fromLine: line).isEmpty)
    }
}

// MARK: - Attachment chips

@Test func attachmentSizesReadTheWayTheDesignWritesThem() {
    #expect(MessageHeaderText.attachmentSize(84_000).contains("KB"))
    #expect(MessageHeaderText.attachmentSize(1_200_000).contains("MB"))
}

@Test func attachmentIconsMatchTheBroadFileKind() {
    #expect(MessageHeaderText.attachmentIcon(forMimeType: "application/pdf") == "doc.richtext")
    #expect(MessageHeaderText.attachmentIcon(forMimeType: "image/png") == "photo")
    #expect(MessageHeaderText.attachmentIcon(forMimeType: "application/zip") == "doc.zipper")
    #expect(
        MessageHeaderText.attachmentIcon(forMimeType:
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") == "tablecells")
    // Unknown types get a generic document rather than no chip at all.
    #expect(MessageHeaderText.attachmentIcon(forMimeType: "application/x-whatever") == "doc")
}
