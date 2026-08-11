# Hudson — Distribution & Live-Test Status

_Last updated: 2026-08-12_

Snapshot of the "download → install → first launch → read mail" experience,
after a full end-to-end live test on a real 2700-message Gmail account.

---

## ✅ Working end-to-end (all on `main`, pushed, 613 tests green)

| Piece | Status |
|---|---|
| **Real app icon** | Deep-green Hudson mark baked into the `.app` |
| **Signed + notarized installer** | `dist/Hudson-0.1.0.dmg` — Developer ID + Apple-notarized + stapled. No Gatekeeper warning. |
| **One-click "Sign in with Google"** | Shared OAuth client (project `hudson-mail`, published) wired into `SharedOAuth`; secret build-injected. Verified: signed in with a fresh account, zero credential pasting. |
| **First-launch onboarding** | Welcome → Google → unverified explainer → connected |
| **Disconnect account** | Settings → Account → Disconnect → back to onboarding |
| **Inbox list + Primary tab** | Shows real mail (Gmail Primary = CATEGORY_PERSONAL, fixed) |
| **Reading pane** | Opens any thread instantly (on-demand body fetch), quoted replies collapsed behind "···", HTML entities decoded, honest "Getting your mail…" status |

**A friend can install and use this today.**

---

## 🔧 Fixed today (live-test round)

1. **Primary tab was empty** — `CATEGORY_PERSONAL` now routes to the `primary` split (Gmail's Primary *is* the personal category).
2. **"All synced" lied** — footer now shows "Getting your mail…" while bodies stream in; sync loop fills fast (2s) while catching up.
3. **Threads stuck "loading"** — reading pane now fetches a message body **on demand** the moment you open it (`SyncEngine.hydrate` + `ThreadModel.hydrateBody`), bypassing the slow background backfill.
4. **`&#39;` in previews** — `HTMLEntities.decode` applied to snippets (inbox, reading pane, search).
5. **Opening a reply showed the whole thread** — quoted history (`.gmail_quote` / `blockquote[type=cite]`) collapsed behind a "···" toggle.

## 🐢 Known follow-ups (not blocking, next session)

- **Slow background backfill** — metadata is fetched one message at a time, so a large mailbox takes a while to fully cache (search/scroll of old mail lags). On-demand fetch means this no longer blocks *reading*. Fix: parallelize/batch the metadata fetch.
- **White email card** — email HTML renders on a white card (correct for email; Superhuman/Gmail do the same). Open design choice: keep / warmer off-white / theme-adapt simple emails.

---

## 🔑 Credentials (already set up — survive restart)

- **Apple Developer ID:** `Developer ID Application: Mannas Narang (74YRG64DGB)` — login Keychain
- **Apple notary profile:** `hudson-notary` — Keychain (Apple ID `mannasn@icloud.com`, team `74YRG64DGB`)
- **Google shared OAuth client:** id compiled into `SharedOAuth` (public); secret in git-ignored `scripts/hudson-secrets.env` (re-obtainable from Google Cloud → Credentials if ever lost)

## 🔁 Rebuild the notarized installer (one command)

```bash
source scripts/hudson-secrets.env      # loads DEVELOPER_ID, NOTARY_PROFILE, HUDSON_OAUTH_CLIENT_SECRET
./scripts/make-dmg.sh                   # build → sign → inject secret → notarize → staple
```
Output: `dist/Hudson-0.1.0.dmg`. For a quick local rebuild without notarizing:
`source scripts/hudson-secrets.env && ./scripts/package-app.sh release && codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" dist/Hudson.app`

_Note: the currently-installed `/Applications/Hudson.app` is a signed (not notarized)
local build from the live-test loop. Re-run `make-dmg.sh` for the notarized DMG to hand to friends._

---

## What survives a restart

Everything: `/Applications/Hudson.app`, the local mail DB (`~/Library/Application Support/Hudson/`),
the Keychain (tokens + secret), and the git repo (fully pushed to `github.com/mannasdev/hudson`).
The only local-only file is `scripts/hudson-secrets.env` — it's on disk and persists; it's just
not on GitHub, on purpose.

## Next session, in order

1. Re-cut the notarized DMG (`make-dmg.sh`) and host it behind the website download button
2. (optional) Speed up background backfill; decide on the email-card look
3. Share with friends 🎉
