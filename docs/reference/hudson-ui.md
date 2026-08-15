# HudsonUI

`Sources/HudsonUI/` — the SwiftUI app: 47 files across view models, views, a
design-token theme, and text-handling utilities. `HudsonApp` is a one-file
executable that mounts `RootView`.

Depends on every other library target. Cannot depend on `HudsonCLI`
(dependencies run executable → library, never the reverse), which is why a few
bootstrap wirings are deliberately duplicated rather than shared.

```bash
swift run HudsonApp          # the real mailbox
swift run HudsonApp --demo   # ~40 synthetic threads, no account needed
```

See [running-the-app.md](../ui/running-the-app.md) for the keyboard map,
screenshots, and demo mode.

## Layout

```
HudsonUI/
├── Model/       view models, bootstraps, keyboard routing, demo data
├── Views/       SwiftUI screens and overlays
├── Components/  small reusable atoms
├── Theme/       Palette, Metrics, Typography, Motion
├── Util/        body parsing, HTML entities, quoted-text collapsing
└── Resources/   bundled fonts
```

## The object graph

`AppModel` is the root. It is `@MainActor @Observable`, owns the open
database and the active account, and constructs every child view model.

```
AppModel
├── inbox      InboxModel      the thread list, split tabs, selection, triage
├── thread     ThreadModel     the open thread + on-demand body hydration
├── command    CommandModel    the ⌘K palette's entries and fuzzy filtering
├── search     SearchModel     debounced FTS search
├── settings   SettingsModel   AI configuration sheet
├── composer   ComposerModel   compose / reply / send / undo-send
└── summary    SummaryModel    the Summarize chip for the open thread
```

Plus app-level state: `isPaletteVisible`, `isSearchVisible`,
`isComposerVisible`, `isSettingsVisible`, `sidebarSelection`, `syncBanner`,
`isSyncing`, `isCatchingUp`, `pendingCount`, `totalUnread`, `labels`.

### Initializers

```swift
try await AppModel(databaseURL: url, tokenStore: nil)   // production
AppModel(database: db, account: rec, isDemo: false, tokenStore: …)  // tests/previews
try await AppModel.demo()                               // the --demo mailbox
```

`needsOnboarding` is `account == nil && !isDemo`. `RootView` gates on it, so a
fresh install sees `OnboardingView` rather than an empty three-pane window.

### Background sync

`startAutoSync(interval: .seconds(30))` runs a loop that polls history,
flushes the triage queue, and drains the send queue. While a fresh account is
still catching up (backfill incomplete, or bodies hydrated this pass) it loops
every 2 seconds instead of 30, so a new mailbox fills in about a minute rather
than fifteen; `isCatchingUp` drives the footer's honest "Getting your mail…"
rather than claiming "All synced" mid-hydration.

The loop is deliberately **quiet** — it never touches `isSyncing`/`syncBanner`
(those belong to the manual "Sync now" button), and a failed pass just waits
for the next tick. It is a no-op under `--demo` or with no stored credentials.

This is not a privacy departure: it fetches the user's own mail directly,
Mac ↔ Gmail, no server. What is banned is background *AI*, and none runs here.

### disconnectAccount

Clears Keychain tokens, then deletes the `accounts` row — **in that order,
deliberately**. Both `TokenStore` implementations treat deleting a missing
entry as a no-op, so a failure in step one changes nothing and a retry starts
from the same state. The reverse order would risk the worse failure: the
`accounts` row gone (hiding the Disconnect affordance) while orphaned tokens
survive with no UI left to retry removing them.

Neither delete is swallowed. A partial failure surfaces a banner and leaves
`account` set, so the app never claims to have forgotten an account it still
has a live trace of.

It does **not** delete already-synced mail. Disconnect forgets the connection,
not the mailbox.

## Keyboard routing

Three files, one pure function.

```swift
public enum KeyboardContext { case palette, search, composer, list }

public struct KeyDescriptor: Sendable, Equatable {
    public var characters: String?
    public var special: SpecialKey?   // upArrow, downArrow, return, escape
    public var command: Bool
}

public enum KeyAction: Sendable, Equatable { … }

KeyRouter.route(_ key: KeyDescriptor, in context: KeyboardContext) -> KeyAction?
```

`KeyboardMap.swift` contains **no AppKit** — no `NSEvent` anywhere — so every
routing rule is unit-testable without a live event loop or window server.
`Views/KeyboardMonitor.swift` is the only adapter that builds a
`KeyDescriptor` from a real `NSEvent`. `AppModel.apply(_:)` interprets the
resulting action and makes no routing decisions of its own.

`AppModel.keyboardContext` is **derived, never stored**, so it cannot drift
from the overlay flags that actually drive what is on screen. The composer and
settings sheets both map to `.composer`: they are text-entry modals, so the
list's single-letter triage shortcuts (`j`/`k`/`e`/`s`/`u`/`o`) must not eat
characters you are typing.

`route` returning `nil` means "not ours" — let AppKit/SwiftUI have the key.

Full key table: [running-the-app.md](../ui/running-the-app.md#keyboard-map).

## Triage

`Triage.swift` holds one-shot optimistic actions, each enqueuing exactly the
label delta Gmail's own affordance would produce. Because `enqueueMutation`
recomputes `thread_rollup` in the same transaction, a caller **never** mutates
a view model's `rows` afterward — the next `observeInboxThreads` emission
already reflects it.

**Thread-level vs message-level is a real distinction.**
`thread_rollup.in_inbox`/`unread` are OR-aggregates across every message in a
thread. So archiving only the newest message is a silent no-op on a
multi-message thread whenever an older message still carries `INBOX` — the
rollup recomputes straight back to `true` and the thread never leaves the
list. `archiveThread`/`markReadThread` therefore enqueue the delta on **every**
message in the thread that carries the label.

Starring and marking unread stay scoped to one message, because that is what
they are in Gmail itself.

## View models

| Model | Notes |
|---|---|
| `InboxModel` | Observes `inboxThreads`, builds split tabs, owns selection and `j`/`k` movement, exposes `archiveSelected`/`toggleStarSelected`/`toggleReadSelected`. `mailbox` is `.inbox` or `.label(id:title:)`. |
| `ThreadModel` | Observes the open thread; expands/collapses messages; fetches a body **on demand** the moment you open a message, bypassing the slow background backfill. |
| `SearchModel` | Debounced, cancellable search. Each keystroke cancels the previous task before its sleep elapses; every state write after an `await` is guarded by `Task.isCancelled`, so a stale search can never clobber newer results. |
| `CommandModel` | Palette entries + `FuzzyMatch` ranking. `Command.id` is stable across `filter()` re-runs so list diffing has a key. |
| `ComposerModel` | New compose, reply-with-threading, durable send, undo-send. Nothing sends on its own — a job reaches the wire only because the user tapped Send. |
| `SummaryModel` | The Summarize chip. The **one** place in the UI that mints `Invocation.userInvoked(.summarize)`, and only from the tap handler — never on thread-open or scroll. |
| `SettingsModel` | Writes the same `ai_config` rows and `LLMKeyStore` entries `hudson ai config` does. |
| `OnboardingModel` | In-app "Sign in with Google" — the graphical port of `AuthCommand.connect`, ordering preserved. Every leg runs on this Mac. |

### Bootstraps

`SyncBootstrap`, `SendBootstrap`, and `AIBootstrap` each build a stack from
the Keychain + database for one account, returning `nil` when credentials or
opt-in are absent. **Fail-closed by construction**: `AIBootstrap` returns
`nil` for a feature that is not opted in, so no provider is ever built and the
surface degrades to a "turn AI on" affordance instead of egressing.

The Keychain → `GmailClient` wiring is duplicated across `SyncBootstrap` and
`SendBootstrap` deliberately — a handful of lines, serving different callers
that should stay free to evolve their own credential handling.

`SharedOAuth` resolves which OAuth client feeds the sign-in flow: the bundled
Hudson-branded Desktop client by default, the user's own BYO client otherwise.
**Identity only, never a data path.** The client ID is a compiled constant
(Google does not treat a Desktop client id as confidential); the secret is
never hard-coded — it is injected at build time and resolved at call time, so
a source checkout alone never contains it.

`LazyHydrator` defers `SyncBootstrap.makeHydrator`'s Keychain lookup to the
first on-demand body fetch rather than doing it on every `AppModel`
construction. It is an `actor`, so the build-once cache is safe without a lock
and the closure it hands out satisfies `@Sendable`.

## Views

`RootView` assembles the three-pane shell and gates onboarding. `SidebarView`
(folders + labels + the sync footer), `InboxListView`, `ThreadView` (the
reading pane, reply bar, Summarize chip), `CommandPaletteView`, `SearchView`,
`ComposerView`, `SettingsView`, `OnboardingView`, `HTMLMessageView`,
`KeyboardMonitor`.

Components: `Banner`, `Buttons`, `Chip`, `EmailRow`, `InboxTab`, `Keycap`,
`SenderAvatar`, `SidebarItem`, `Toast`.

## Theme

Design tokens lifted from the Pencil design system. **Views reference tokens,
never literals** — no raw hex, no hard-coded point values, no inline
`.spring(response:)`.

| File | Contents |
|---|---|
| `Palette` | Named colors — `bgApp`, `bgSurface`, `accent`, `ink`, … |
| `Metrics` | `unit = 4.0`; every padding and gap is a multiple. Radii, `sidebarWidth`, … |
| `Typography` | Type scale over the bundled fonts in `Resources/` |
| `Motion` | Named transitions. Nothing runs longer than 280 ms, most land inside 180 ms — past a quarter-second a transition stops reading as feedback and starts reading as latency. Anything that moves or resizes gets a spring; anything purely a fade gets an ease. |

## Util

- `MessageBodyParser` / `SimpleBody` — turn a stored body into renderable parts
- `BodyAttributedString` — native prose rendering
- `HTMLEntities.decode` — applied to snippets everywhere (inbox, reading pane, search)
- `QuotedText` — collapses `.gmail_quote` / `blockquote[type=cite]` history behind a "···" toggle
- `MessageHeaderText` — From/To/date formatting

## Tests

`Tests/HudsonUITests/` — 27 files. `KeyboardMapTests` covers every routing
rule; `RenderSmokeTests` hosts the assembled `RootView` in an `NSHostingView`
at 1200×760 to prove it renders; one test file per view model; `SnapshotHarness`
regenerates the doc screenshots (a no-op unless `HUDSON_SNAPSHOT=1`).

Pixel-level fidelity against the design is a live-run, eyeball check —
`swift run HudsonApp --demo`, screenshot, compare — not something a headless
test asserts.

## Related

- [running-the-app.md](../ui/running-the-app.md) — keyboard map, demo mode, screenshots
- [ui-design-brief.md](../design/ui-design-brief.md) — the design system
- [Store](store.md) — every view model's data source
- [ai-privacy-model.md](../explanation/ai-privacy-model.md) — why `SummaryModel` is the only minting site
