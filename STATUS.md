# Hudson — Distribution Status

_Last updated: 2026-08-11_

Snapshot of the "download → install → first launch" experience for sharing Hudson with friends.

---

## ✅ Done & shippable (all merged to `main`, pushed to GitHub, 601 tests green)

| Piece | Detail |
|---|---|
| **Real app icon** | Deep-green Hudson mark baked into the `.app` (`Design/AppIcon/Hudson-1024.png` → `.icns` at package time) |
| **Signed + notarized installer** | `dist/Hudson-0.1.0.dmg` — Developer ID signed, Apple-notarized, stapled, Gatekeeper-accepted. **No "cannot be opened" warning.** |
| **Drag-to-Applications DMG** | Mounts as "Hudson" with an Applications symlink |
| **First-launch onboarding** | Welcome → "Sign in with Google" → unverified-app explainer → done (BYO-credentials fallback built in) |
| **Disconnect account** | Settings (gear) → Account → Disconnect → returns to onboarding. Clears Keychain tokens + account row; aborts with a banner if the purge fails (no silent privacy leak). Your synced mail stays on disk. |

A friend can install cleanly **today** — they'd just paste their own Google credentials on first run (see below for the one-click upgrade).

---

## ⏳ The ONE thing left for true one-click "Sign in with Google"

Create a **Google OAuth Desktop client** and send me the Client ID + secret.

1. [console.cloud.google.com](https://console.cloud.google.com) → new project **"Hudson"**
2. **APIs & Services → Library → Gmail API → Enable**
3. **OAuth consent screen** → External → app name + your email → add scope `https://www.googleapis.com/auth/gmail.modify` → **Publish app**
   _(Unverified + published = up to 100 users, no weekly re-login, one "unverified" click. No Google verification / CASA needed under 100 users.)_
4. **Credentials → Create Credentials → OAuth client ID → Application type: Desktop app** → "Hudson Desktop"
5. Send me:
   - **Client ID** — looks like `xxxxx.apps.googleusercontent.com`
   - **Client secret** — looks like `GOCSPX-xxxxxxxx`

**Where it plugs in:** `Sources/HudsonUI/Model/SharedOAuth.swift` → `clientID` (currently `""`), secret injected at build time via `HUDSON_OAUTH_CLIENT_SECRET` (never committed).

---

## 🔑 Credentials already set up (don't redo these)

- **Apple Developer ID:** `Developer ID Application: Mannas Narang (74YRG64DGB)` — in login Keychain
- **Apple notary profile:** `hudson-notary` — saved in Keychain (Apple ID `mannasn@icloud.com`, team `74YRG64DGB`). App-specific password already stored; never needed again.
- **These are Apple credentials** (for notarizing the installer) — separate from the Google OAuth client above.

---

## 🔁 Rebuild the notarized installer (one command)

```bash
DEVELOPER_ID="Developer ID Application: Mannas Narang (74YRG64DGB)" \
NOTARY_PROFILE="hudson-notary" \
./scripts/make-dmg.sh
```
Output: `dist/Hudson-0.1.0.dmg` (signed + notarized + stapled). Takes ~2–5 min (Apple notary wait).
_Rebuilding also recreates a loose `dist/Hudson.app` — that's a build intermediate, not a second install._

---

## ⏸️ Optional / deferred (not blocking a friend install)

- **Styled DMG window** — background image with a "drag Hudson → Applications" arrow
- **Sparkle auto-update** — push updates without re-downloading
- **Google verification / CASA** — only needed to go past 100 users
- **Open-sourcing publicly** — repo is currently private (`github.com/mannasdev/hudson`)

---

## Next session, in order

1. You: create the Google OAuth client (steps above) → send me Client ID + secret
2. Me: bake it into `SharedOAuth`, re-cut the DMG → true one-click sign-in
3. You: host `Hudson-0.1.0.dmg` behind the website download button
4. Share with friends 🎉
