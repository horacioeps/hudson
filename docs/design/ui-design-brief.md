# Hudson — UI Design Brief

**For:** product designer (external)
**Deliverable:** complete UI design for a Mac-native email client
**Date:** 2026-08-10

## What Hudson is

Hudson is a free, open-source, Mac-native Gmail client with one promise: **the fastest email experience on the Mac, owned by no one.** It competes head-on with Superhuman ($25–40/mo) on speed and polish, and with Slashy on AI — but it costs nothing, the code is open, and users bring their own AI API keys. There is no server, no account, no subscription.

**Reference points:**
- **Superhuman** — the bar for keyboard-first speed, triage flow, and the command palette. Steal the *feeling*, not the look.
- **Mimestream** — the bar for "indistinguishable from an app Apple would ship."
- **Slashy / Notion Mail** — how AI surfaces can sit inside email without taking over.
- **Apple Mail** — platform conventions users' hands already know.

## Audience

Developers, founders, and prosumers who live in email: currently paying for Superhuman, tolerating Gmail's web UI, or on Mimestream wishing it had AI. Keyboard-centric. They will happily complete one 5-minute technical onboarding step (creating their own Google OAuth client — see Screen 1) in exchange for free-forever, but they expect ruthless speed every moment after.

## Design principles (the bar)

1. **Speed is the aesthetic.** Every local interaction must *feel* under 100 ms. Motion only where it communicates (roughly 100–200 ms, ease-out); zero decorative animation. No skeleton screens or spinners for local data — data is always already there.
2. **Keyboard-first, mouse-complete.** Every action reachable from the command palette and single-key shortcuts (j/k navigate, e archive, s snooze…). Hover affordances exist but are never required. Shortcut hints appear throughout the UI.
3. **Native, not webby.** macOS 15+ conventions: crisp typography (SF Pro or a deliberate brand alternative), restrained materials/vibrancy, real macOS toolbars and context menus, full light *and* dark mode. This app should feel like it shipped with the Mac.
4. **Calm density.** Dense, scannable list; generous, quiet reading canvas; minimal chrome. Email is a tool, not a feed.
5. **AI is quiet.** AI surfaces are ambient, invoked, and dismissible — a summary chip, a draft side panel — never modal takeovers. The user always reviews before anything sends. AI must degrade gracefully to invisible when no API key is configured.

## Screens & flows to design

Every screen needs loading / empty / error / **offline** states. Offline is a first-class mode (everything local keeps working; a quiet indicator shows sync state).

1. **Onboarding** — the make-or-break flow:
   a. Welcome (what Hudson is, in one screen).
   b. **BYO Google OAuth guided setup** — the hardest design problem in the app. The user must create their own (free) Google Cloud OAuth client: ~6 steps in Google's console, then paste one Client ID into Hudson. Design this as a confident, step-by-step guided flow (progress indicator, one step per screen, annotated visuals of Google's console, "verify" checkpoints, recovery when a step fails). It must feel like a concierge setup, not a README.
   c. LLM key setup — provider picker (Anthropic / OpenAI-compatible / local via Ollama), paste key, "test" button, explicitly skippable ("add AI later").
   d. 30-second interactive shortcut tutorial (the Superhuman trick: teach j/k/e/s by doing).
   e. First-sync screen — inbox streams in live; usable before backfill completes.
2. **Main window** — list + reading pane, and list-only layout. Split-inbox tabs across the top (Important / Team / News / Promotions-style streams, user-configurable). Unified toolbar, sync/offline indicator, multi-select, density comfortable at 13" and glorious at 32".
3. **Thread view** — conversation stack with collapsed quoting, attachment row, remote-image shield banner, inline **AI summary chip** (one line, expandable, cached — never blocks reading).
4. **Composer** — inline reply at thread bottom + detachable window. Recipient chips with autocomplete, subject, minimal formatting toolbar, attachment affordance, **send-later** control next to Send, and the **AI draft panel**: instruction field → streamed draft → accept / edit / retry. Draft-in-your-voice is the hero AI feature.
5. **Command palette (⌘K)** — the signature surface. Actions, navigation, and search in one fuzzy-matched list with shortcut hints and context awareness (thread selected vs. inbox).
6. **Search** — instant local results as-you-type, query chips (`from:`, `has:attachment`, `in:`), full-mailbox scope.
7. **Snooze picker** — preset grid (later today / tonight / tomorrow 9am / weekend / next week / pick date), number-key selectable, natural-language input.
8. **Ask-inbox** — question in, cited answer out; citations are tappable message references that open the thread. Feels like asking a chief of staff, renders like a quiet panel — not a chatbot cosplay.
9. **Settings** — Accounts (incl. re-auth state), AI (provider, base URL, model, key), Shortcuts (viewable, remappable), Split-inbox rules, Appearance.
10. **System surfaces** — app icon (macOS squircle; must be distinctive in a dock full of blue apps), menu bar extra (optional), dock badge, native notifications with actions (Archive / Snooze / Reply), and the **inbox-zero moment** — the one sanctioned place for delight.

## Motion & feel

Archive/triage: row exits fast (~150 ms) with subtle spring, list closes the gap immediately — triage should feel like dealing cards. Palette and pickers appear instantly (≤100 ms, slight scale-in). Reduced-motion variants for everything.

## Deliverables requested

1. **Design system:** type scale, color tokens (light + dark), spacing scale, radii, elevation, and core components (list row, tab, button, field, chips, palette row, toast, banner).
2. **High-fidelity screens:** main window (both layouts × both themes), thread view, composer + AI draft panel, command palette, full onboarding flow, snooze picker, ask-inbox, settings, inbox-zero.
3. **Motion spec:** durations/curves per interaction class.
4. **Keyboard overlay:** the "?" cheat-sheet design.
5. **Brand:** app icon, wordmark treatment for "Hudson." Naming vibe: understated, confident, a bit literary — a river, not a rocket ship.
6. **Format:** Figma, components properly structured; icons from SF Symbols where possible with custom pieces where needed.

## Constraints

- macOS 15+, implemented in SwiftUI — prefer standard controls where excellent, custom where speed demands.
- Accessibility: AA contrast in both themes, complete keyboard navigation (that's the product anyway), VoiceOver labels, reduced-motion.
- Localizable: no baked-in-text images, layouts tolerate +30% string length.
- No web-app affordances: no skeleton loaders, no toast spam, no onboarding checklists floating over the inbox.
