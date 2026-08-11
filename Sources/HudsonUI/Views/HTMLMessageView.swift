import AppKit
import SwiftUI
import WebKit

/// Renders one message's raw, sender-authored HTML — Hudson's real email body
/// view. Email is HOSTILE input, and Hudson's #1 rule is that the default
/// render leaks NOTHING to the network: no remote images (tracking pixels), no
/// remote fonts/CSS/scripts, no beacons. Everything in this file exists to
/// hold that line.
///
/// Two independent layers enforce it, deliberately redundant:
///   1. A strict `Content-Security-Policy` injected into the document head
///      (`HTMLDocument.wrap`) — `default-src 'none'` forbids every network
///      egress; only `data:`/`cid:` images and inline styles are allowed.
///      This is the primary blocker, and it stops SUBRESOURCE loads (images,
///      fonts, background CSS) that a navigation delegate never even sees.
///   2. A `WKNavigationDelegate` (`Coordinator`) that cancels any http/https
///      navigation and hands real link clicks to the default browser — email
///      is read, never browsed, in-app.
///
/// The "Load remote images" affordance below is the ONLY way remote images
/// ever load, and only for that one message, never persisted or global.
struct HTMLMessageView: View {
    let rawHTML: Data
    /// The sanitizer's inventory of remote URLs in this message. When empty
    /// there's nothing remote to load, so the affordance stays hidden.
    let remoteURLs: [String]

    /// Per-message, in-memory opt-in. It resets whenever this view is rebuilt
    /// (a different message, a reopened thread) — remote loading is NEVER
    /// remembered across messages or sessions, by design. This is the whole
    /// point of the privacy rule: the user re-consents every single time.
    @State private var allowRemoteImages = false
    /// Intrinsic content height reported back from the web view, so it lays
    /// out inside the reading pane's outer `ScrollView` with no nested scroll.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.unit * 2) {
            if !remoteURLs.isEmpty && !allowRemoteImages {
                QuietButton(title: "Load remote images") { allowRemoteImages = true }
            }
            WebBodyView(
                documentHTML: HTMLDocument.wrap(
                    bodyHTML: String(decoding: rawHTML, as: UTF8.self),
                    allowRemoteImages: allowRemoteImages),
                contentHeight: $contentHeight)
                .frame(height: max(contentHeight, 1))
                // Email HTML universally assumes a LIGHT background, so render
                // it on a white card for correct contrast even in Hudson's
                // dark UI — the same thing modern dark-mode mail clients do.
                // (WKWebView email content is exempt from the design tokens.)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
    }
}

/// Builds the full HTML document Hudson feeds to WKWebView: the email's own
/// body wrapped in a `<head>` carrying the remote-blocking CSP plus a small
/// baseline stylesheet (light ground, wrapped long words, contained media).
/// Kept as a plain value-producing helper so the CSP wrapping is unit-testable
/// without a live web view.
enum HTMLDocument {
    /// The Content-Security-Policy string. `default-src 'none'` is the load-
    /// bearing clause: it forbids ALL network egress — remote scripts, styles,
    /// fonts, media, frames, and (crucially) images. `img-src data: cid:` still
    /// lets inline base64 and `cid:` (multipart-embedded) images render, since
    /// those never touch the network. `style-src 'unsafe-inline'` lets the
    /// email's own inline styles apply (inline CSS makes no network request).
    ///
    /// The ONLY thing that changes when the user opts in is `img-src` gaining
    /// `https:` — remote IMAGES become loadable, and nothing else. Scripts,
    /// frames, remote CSS/fonts, and `http:` (cleartext) stay blocked forever.
    static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        let imageSources = allowRemoteImages ? "data: cid: https:" : "data: cid:"
        return "default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'; "
            + "font-src data:; media-src data:;"
    }

    /// Wraps a message body fragment in a complete document. The remote `<img>`
    /// tags stay verbatim in the source — it is the injected CSP (not any
    /// rewriting of the HTML) that blocks them, so nothing about the sender's
    /// markup can smuggle a load past the policy.
    static func wrap(bodyHTML: String, allowRemoteImages: Bool) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemoteImages: allowRemoteImages))">
        <style>
        html, body { margin: 0; padding: 12px; background: #ffffff; color: #1b1b1b;
            font: 15px/1.55 -apple-system, ui-sans-serif, system-ui, sans-serif;
            -webkit-text-size-adjust: 100%; word-break: break-word; overflow-wrap: anywhere; }
        img, video, table { max-width: 100%; height: auto; }
        a { color: #2761d8; }
        blockquote { margin: 0 0 0 12px; padding-left: 12px;
            border-left: 2px solid #d9d9d9; color: #555; }
        pre { white-space: pre-wrap; word-break: break-word; }
        </style>
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }
}

/// The WKWebView bridge. Sandboxed (non-persistent data store, no user
/// scripts beyond the height reporter), sized to its content, and wired so
/// links open in the default browser instead of navigating in-app.
private struct WebBodyView: NSViewRepresentable {
    let documentHTML: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(contentHeight: $contentHeight) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Ephemeral store: no cookies/cache/localStorage from a rendered email
        // ever persists — one more reason a beacon has nothing to write to.
        configuration.websiteDataStore = .nonPersistent()

        let userContent = WKUserContentController()
        // A ResizeObserver -> native message bridge keeps the view sized to its
        // content after LATE reflow (web-font swap, image decode, the user
        // loading remote images). macOS's WKWebView exposes no public
        // `scrollView` to KVO `contentSize` on, so this is the portable
        // equivalent of that observation.
        userContent.add(context.coordinator, name: Coordinator.heightMessageName)
        userContent.addUserScript(WKUserScript(
            source: Coordinator.resizeObserverScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Paint white behind the page (email assumes a light ground) so there's
        // no dark flash before content lands; the SwiftUI card behind is white
        // too. `underPageBackgroundColor` is the public knob for this.
        webView.underPageBackgroundColor = .white
        webView.loadHTMLString(documentHTML, baseURL: nil)
        context.coordinator.lastLoadedHTML = documentHTML
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reload ONLY when the document actually changed — e.g. the user tapped
        // "Load remote images", which rewrites the CSP. The height binding also
        // re-runs this method; reloading on those updates would loop forever.
        guard context.coordinator.lastLoadedHTML != documentHTML else { return }
        context.coordinator.lastLoadedHTML = documentHTML
        webView.loadHTMLString(documentHTML, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let heightMessageName = "heightChanged"

        /// Reports `document.body.scrollHeight` on first paint, on window load,
        /// and on every subsequent resize — the single source of truth for the
        /// view's intrinsic height.
        static let resizeObserverScript = """
        (function() {
            function report() {
                var el = document.body || document.documentElement;
                window.webkit.messageHandlers.\(heightMessageName).postMessage(Math.ceil(el.scrollHeight));
            }
            if (window.ResizeObserver) {
                new ResizeObserver(report).observe(document.body || document.documentElement);
            }
            window.addEventListener('load', report);
            report();
        })();
        """

        private let contentHeight: Binding<CGFloat>
        /// The document string currently loaded — guards `updateNSView` against
        /// reloading (and looping) on non-document updates.
        var lastLoadedHTML: String?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        // MARK: Links + remote navigation — never navigate in-app.

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            // The initial in-memory `loadHTMLString` has no real URL (nil or
            // `about:blank`). That's the ONLY navigation allowed to happen
            // inside the web view. Everything else is external content.
            if navigationAction.navigationType == .other,
               url == nil || url?.scheme == nil || url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            // A clicked link, meta-refresh, form post, or any other http/https
            // navigation is cancelled here — email is read, never browsed,
            // in-app (privacy, and it's a mail reader, not a web browser). If
            // it's a real link with a safe scheme, open it in the default
            // browser instead.
            decisionHandler(.cancel)
            if let url, let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
        }

        // MARK: Dynamic height

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.disableInternalScrolling(webView)
            // First authoritative measurement; the ResizeObserver bridge takes
            // over for any later reflow.
            Task { @MainActor in
                let result = try? await webView.evaluateJavaScript(
                    "Math.ceil(document.body.scrollHeight)")
                if let number = result as? NSNumber {
                    self.contentHeight.wrappedValue = CGFloat(truncating: number)
                }
            }
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.heightMessageName else { return }
            if let number = message.body as? NSNumber {
                contentHeight.wrappedValue = CGFloat(truncating: number)
            }
        }

        /// The web view sizes to its full content and must NOT scroll on its
        /// own — the reading pane's SwiftUI `ScrollView` owns scrolling. WebKit
        /// exposes no public handle to the internal scroll view on macOS, so
        /// walk the subview tree once (after `didFinish`, when it exists) and
        /// switch off its scrollers and rubber-banding.
        private static func disableInternalScrolling(_ webView: WKWebView) {
            func firstScrollView(in view: NSView) -> NSScrollView? {
                for subview in view.subviews {
                    if let scroll = subview as? NSScrollView { return scroll }
                    if let found = firstScrollView(in: subview) { return found }
                }
                return nil
            }
            guard let scroll = firstScrollView(in: webView) else { return }
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.verticalScrollElasticity = .none
            scroll.horizontalScrollElasticity = .none
            scroll.drawsBackground = false
        }
    }
}
