# U1 reading-pane UX fixes

Branch `u1-ux` (worktree `.worktrees/u1-ux`). `swift build` green, `swift test`
green (353 tests, was 347 + 6 new). One commit per logical fix.

## Fix 1 — click anywhere on a row opens it
`Sources/HudsonUI/Views/InboxListView.swift`

The row was already wrapped in a `Button(.plain)`, but `.contentShape(Rectangle())`
was applied to the **outer Button**, which does not change the label's own
hit region. Under `.buttonStyle(.plain)` a transparent label only hit-tests
where it actually draws, and an unread/unselected `EmailRow` has a `.clear`
background — so clicks in the empty gutter (right of the snippet, in the
vertical padding) missed. Fix: moved `.frame(maxWidth:.infinity)` +
`.contentShape(Rectangle())` **inside** the button label (onto `EmailRow`), so
every pixel of the 72pt row is a valid tap target. Selection/hover styling
unchanged.

## Fix 2 — resizable columns + real empty state
`RootView.swift`, `InboxListView.swift`, `SidebarView.swift`

- Removed the hard `.frame(width: Metrics.listWidth)` (list) and
  `.frame(width: Metrics.sidebarWidth)` (sidebar). Both now fill width, and
  `RootView.threePane` assigns each column a
  `.navigationSplitViewColumnWidth(min:ideal:max:)` — sidebar `200 / 224 / 320`,
  list `320 / 384 / 560`. Both dividers now drag; the detail (reading) pane
  takes the remaining, resizable space.
- Empty state: the detail closure now gates on
  `model.inbox.selectedThreadID != nil && !model.thread.messages.isEmpty`.
  With nothing open it shows a bare centered `envelope` SF Symbol +
  "Select a conversation" (`Palette.inkTertiary` on `Palette.bgSurface`),
  so `ThreadView`'s chrome (toolbar, reply bar) never renders for an empty pane.
  `ThreadView` is only mounted once a thread has loaded.

## Fix 3 + 5 — render HTML mail, privacy-safe, clickable links
`Sources/Store/StoreReads.swift`, `Model/ThreadModel.swift`,
`Views/HTMLMessageView.swift` (new), `Views/ThreadView.swift`

- **Store:** added `struct MessageBody { plainText, rawHTML, remoteURLs,
  cidReferences }` and `messageBody(id:account:)`, decoding
  `remote_urls`/`cid_references` from the same JSON encoding `saveBody` wrote.
- **ThreadModel:** `ThreadMessage` now carries `rawHTML` + `remoteURLs`,
  hydrated via `messageBody` (same lazy load-and-cache contract; a `nil` read
  = not-yet-hydrated, left uncached to retry).
- **HTMLMessageView** (`NSViewRepresentable` over `WKWebView`): renders raw
  HTML on a **white rounded card** (`Metrics.radiusMedium`; email assumes a
  light ground), sizes to content (no nested scroll — internal scrollers
  disabled, height reported back), text natively selectable.
- **ThreadView.bodyText(for:):** renders `HTMLMessageView` when `rawHTML` is
  non-empty, else the plain-text fallback.

### The exact remote-blocking mechanism (Hudson's #1 rule)
Two independent, redundant layers; the default state makes **zero** network
requests:

1. **Injected CSP** (`HTMLDocument.wrap`, the primary blocker — it stops
   *subresource* loads a nav delegate never sees):
   `default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:; media-src data:;`
   `default-src 'none'` forbids all egress (scripts, fonts, remote CSS, media,
   frames, images). Only `data:`/`cid:` images and inline styles — none of
   which touch the network — are allowed.
2. **`WKNavigationDelegate`** cancels any `http`/`https` navigation; a
   `.linkActivated` (or any real link) is opened in the default browser via
   `NSWorkspace.shared.open`. Email is read, never browsed, in-app. Only the
   initial in-memory `loadHTMLString` (no URL / `about:`) is allowed.

**"Load remote images"** (`QuietButton`, shown only when `remoteURLs` is
non-empty) is the ONLY way remote images load. On tap it re-wraps the document
with `img-src` gaining `https:` — and nothing else loosens (scripts, frames,
remote CSS/fonts, cleartext `http:` stay blocked). It is **per-message and
in-memory**: the `@State` resets on every rebuild, never persisted, never
global. The web view also uses a `.nonPersistent()` data store.

## Fix 4 — selectable text + linkified plain-text fallback
`Views/ThreadView.swift`

- Plain-text body, subject, and sender name/address are `.textSelection(.enabled)`.
- `PlainTextLinkifier.attributed(_:)` runs `NSDataDetector` over the plain text
  and adds `.link` runs for **http/https/mailto only** (anything else stays
  inert — no `file:`/`javascript:`/custom schemes). `Text(AttributedString)`
  renders them tappable; taps go through SwiftUI's default `openURL` → browser.

## Tests
- Store: `messageBodyReturnsHTMLAndRemoteInventory`,
  `messageBodyReturnsNilBeforeHydration` (`StoreReadsTests`).
- ThreadModel: `openExposesRawHTMLAndRemoteURLsForHTMLBody` (`ThreadModelTests`).
- HTML wrapper + linkify: `HTMLRenderingTests` (4 tests) — asserts the blocking
  CSP is injected while a remote `<img>` survives verbatim in the source, that
  opt-in only adds `https:` to `img-src`, and that a URL becomes a `.link` run.

## Caveats / couldn't verify without a live run
- **Live WKWebView rendering is not asserted headlessly.** `swift test` can't
  drive a real web view, so the CSP-blocking, link-open, dynamic-height, and
  white-card behaviors are covered at the value/wrapper layer (the exact CSP
  string, the linkify runs) and by inspection — not by a live load. The
  controller should verify these visually.
- **macOS has no public `WKWebView.scrollView`.** The task mentioned KVO on
  `scrollView.contentSize`; on macOS that handle isn't public, so late reflow
  is observed via a `ResizeObserver` → `WKScriptMessageHandler` bridge instead
  (portable equivalent). Internal scrolling is disabled by walking the subview
  tree for the private `NSScrollView` after `didFinish` (best-effort; if the
  hierarchy ever changes it simply falls back to the content-sized frame, which
  already prevents scrolling since the view is sized to full content).
- **Demo DB is cached.** `AppModel.demo()` seeds `$TMPDIR/hudson-demo.sqlite`
  only when empty. To see the new HTML demo email (`t31`, Fernwood promo — a
  remote hero image blocked by default + a clickable "Shop the sale" link) and
  the linkified plain body (`t29`), **delete `$TMPDIR/hudson-demo.sqlite`
  before launching `--demo`**, or it renders the previously-seeded mailbox.
- The "Load remote images" affordance keys off `remoteURLs`, which the
  sanitizer populates from both image `src` and link `href`. A message with
  remote *links* but no remote *images* will still show the button (tapping it
  is a harmless no-op for that message). Left as-is per the spec's
  `remoteURLs`-gated affordance.
