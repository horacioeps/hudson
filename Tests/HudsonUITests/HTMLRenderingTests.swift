import Foundation
import Testing
@testable import HudsonUI

// MARK: - HTMLDocument (the remote-blocking CSP wrapper)

/// The privacy contract, asserted at the wrapping layer: by default the
/// injected CSP forbids all network egress and only allows `data:`/`cid:`
/// images — so even though a remote `<img>` is present verbatim in the source,
/// the browser can never load it. Live WKWebView rendering can't be asserted
/// headlessly under `swift test`, so this proves the mechanism (the exact CSP
/// string) is present in the document the web view is handed.
@Test func wrappedDocumentInjectsRemoteBlockingCSPAndKeepsBodyVerbatim() {
    let body = "<p>Hello</p><img src=\"https://tracker.example/pixel.gif\">"
    let document = HTMLDocument.wrap(bodyHTML: body, allowRemoteImages: false)

    // The blocking policy is present...
    #expect(document.contains("default-src 'none'"))
    #expect(document.contains("img-src data: cid:"))
    // ...and, while blocked, it does NOT grant remote https images.
    #expect(!document.contains("img-src data: cid: https:"))
    // The remote <img> survives verbatim in the source — it's the CSP, not any
    // rewriting of the markup, that blocks the load.
    #expect(document.contains("https://tracker.example/pixel.gif"))
    // Scripts/objects are never allowed, even in the default policy.
    #expect(document.contains("default-src 'none'"))
}

/// The ONLY thing the "Load remote images" opt-in changes is `img-src` gaining
/// `https:` — nothing else in the policy loosens.
@Test func loadingRemoteImagesOnlyAddsHTTPSToImgSrc() {
    let body = "<img src=\"https://cdn.example/a.png\">"
    let blocked = HTMLDocument.contentSecurityPolicy(allowRemoteImages: false)
    let allowed = HTMLDocument.contentSecurityPolicy(allowRemoteImages: true)

    #expect(blocked == "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; "
        + "font-src data:; media-src data:;")
    #expect(allowed == "default-src 'none'; img-src data: cid: https:; style-src 'unsafe-inline'; "
        + "font-src data:; media-src data:;")
    // The document with opt-in still carries the strict default-src.
    let document = HTMLDocument.wrap(bodyHTML: body, allowRemoteImages: true)
    #expect(document.contains("img-src data: cid: https:"))
    #expect(document.contains("default-src 'none'"))
}

// MARK: - PlainTextLinkifier (clickable links in the plain-text fallback)

@Test func linkifyMakesURLsTappableLinkRuns() {
    let attributed = PlainTextLinkifier.attributed(
        "See https://example.com and mail me@example.com for details.")

    let linkedURLs = attributed.runs.compactMap(\.link)
    #expect(linkedURLs.contains(URL(string: "https://example.com")!))
    // A bare email becomes a mailto: link (NSDataDetector normalizes it).
    #expect(linkedURLs.contains(URL(string: "mailto:me@example.com")!))
}

@Test func linkifyLeavesPlainTextWithoutURLsInert() {
    let attributed = PlainTextLinkifier.attributed("Just some ordinary text, no links here.")
    #expect(attributed.runs.allSatisfy { $0.link == nil })
    // Round-trips the characters unchanged.
    #expect(String(attributed.characters) == "Just some ordinary text, no links here.")
}
