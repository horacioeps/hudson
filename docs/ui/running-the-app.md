# Running the Hudson Mac app

This is the SwiftUI shell over the headless foundation: a three-pane mailbox
(sidebar / inbox list / reading pane), instant keyboard-first triage, a ⌘K
command palette, local full-text search, compose and reply with undo-send, and
an explicitly-invoked AI summary chip. It syncs on its own — a background loop
polls for new mail and drains the triage and send queues — with a manual "Sync
now" in the sidebar footer.

Snooze is the one surface still stubbed; see
[Stubbed / deferred](#stubbed--deferred-until-a-later-milestone) below.

## Screenshots

Rendered from the `--demo` mailbox (synthetic data — no real mail):

| Main window | Command palette (⌘K) | Search |
|---|---|---|
| ![Three-pane main window](screenshots/main-window.png) | ![Command palette](screenshots/command-palette.png) | ![Full-text search](screenshots/search.png) |

Regenerate them with the offscreen render harness (no display / screen-recording
permission needed — it captures each view's own backing store):

```bash
HUDSON_SNAPSHOT=1 HUDSON_SNAPSHOT_DIR=docs/ui/screenshots \
  swift test --filter SnapshotHarness
```

The harness (`Tests/HudsonUITests/SnapshotHarness.swift`) is a no-op unless
`HUDSON_SNAPSHOT=1`, so it never runs in the normal suite.

## Build and run

Requires macOS 15+ and Xcode 16+ (same prerequisites as the CLI — see the
[root README](../../README.md)).

```bash
swift build
swift run HudsonApp
```

`HudsonApp` opens the SAME database the CLI reads and writes
(`~/Library/Application Support/Hudson/hudson.sqlite` —
`HudsonDatabase.defaultDatabaseURL`), so the app and `hudson` are peers over
one mailbox. On first launch the app's own onboarding connects a Google
account; you can also connect from the CLI with `hudson auth`.

**Reads and triage are always local.** Opening a thread, scrolling, searching,
and archive/star/mark-read all resolve against SQLite — none of them waits on
the network. The network runs on a background loop that polls Gmail, flushes
queued triage, and drains queued sends. It fetches your own mail directly,
Mac ↔ Gmail, with no server in between.

The one thing that never runs on its own is AI: the Summarize chip egresses
only when you tap it, and only for a feature you opted in. See
[ai-privacy-model.md](../explanation/ai-privacy-model.md).

### Demo mode

To explore the UI without a real Google account or any synced mail:

```bash
swift run HudsonApp --demo
# or: HUDSON_DEMO=1 swift run HudsonApp
```

This opens a separate, fixed-path temp database and seeds it with ~40
synthetic threads (`DemoData`) on first launch — entirely fictional senders,
subjects, and bodies on `.example` domains (RFC 2606), never your real
mailbox. Re-running `--demo` reuses the same seeded database rather than
re-seeding it.

## Keyboard map

Every shortcut below is routed by a single pure function, `KeyRouter.route`
(`Sources/HudsonUI/Model/KeyboardMap.swift`), driven by an app-wide `NSEvent`
monitor (`KeyboardMonitor`) rather than SwiftUI's `.onKeyPress` — see that
file's doc comment for why. `KeyboardMapTests` unit-tests every routing rule
below directly, without a live event loop.

### Inbox list (default, no overlay open)

| Key | Action |
|---|---|
| `j` / `k` | Select next / previous thread |
| `↵` or `o` | Open the selected thread in the reading pane |
| `e` | Archive the selected thread |
| `s` | Star / unstar the selected thread |
| `u` | Toggle read / unread |
| `Esc` | Clear the current selection |
| `⌘K` | Open the command palette |
| `⌘F` or `/` | Open search |
| `⌘N` | Compose a new message |

Arrow keys are deliberately unrouted here — they belong to the list's own
scrolling.

Every triage key (`e`/`s`/`u`) enqueues its mutation the same way a click on
the corresponding button would — instantly, optimistically (the row updates
before the (still-local, no-network) write even lands), via
`InboxModel`/`Triage`'s `enqueueMutation` path.

### Command palette (⌘K)

| Key | Action |
|---|---|
| `↑` / `↓` | Move the highlighted command |
| `↵` | Perform the highlighted command |
| `Esc` | Close the palette |
| *(anything else)* | Typed into the query field |

### Search (⌘F or `/`)

| Key | Action |
|---|---|
| `Esc` | Close search |
| *(anything else)* | Typed into the query field |

### Compose / reply sheet (⌘N, or Reply from the reading pane)

| Key | Action |
|---|---|
| `Esc` | Close the sheet |
| *(everything else)* | Typed into the message |

The composer takes keyboard priority precisely so the list's single-letter
shortcuts don't eat characters you're typing — without it you couldn't put a
`j` or an `e` in an email. The Settings sheet shares this context for the same
reason.

## Stubbed / deferred until a later milestone

These surfaces are intentionally present but non-functional — tapping them
shows a `Toast` naming when real behavior arrives, never a silent no-op that
could be mistaken for a bug:

- **Snooze** — listed in the command palette as "Coming soon", and in the
  reading pane's action bar; arrives with **M6**. The sidebar's Snoozed folder
  points at the `Hudson/Snoozed` label, which stays empty until then.
- **"More actions"** (the `⋯` button in the reading pane) — **M6**.
- **Move to split** from the command palette — **M6**.

Everything else in the shell is live: sidebar navigation (Inbox with split
tabs, Starred, Sent, and per-label folders), background + manual sync, compose
and reply with a 15-second undo-send window, and the AI Summarize chip.

## Fidelity note

Automated tests prove the assembled `RootView` renders without crashing
(`RenderSmokeTests.rootViewRendersAssembledThreePane`, hosting it in an
`NSHostingView` at 1200×760) and that every keyboard routing rule is
correct (`KeyboardMapTests`). Pixel-level fidelity against the Pencil
design — spacing, color, exact layout — is a live-run, eyeball-driven check
(`swift run HudsonApp --demo`, screenshot, compare), not something a
headless test can assert.

## See also

- [HudsonUI reference](../reference/hudson-ui.md) — view models, theme, routing
- [UI design brief](../design/ui-design-brief.md) — the design system
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — how the app sits over the foundation
