# Sesión 2026-10-03 — bajar y compilar Hudson

## Pedido

Baja este código y lo compilas para Mac: https://github.com/mannasdev/hudson

## Contexto

Workspace vacío (`Email Mac Hudson Fork`) salvo `.vscode/`. Flujo Horacio: clone en `main`, fork propio para poder pushear, sesiones + HISTORICO.

## Hecho

1. Clone de `https://github.com/mannasdev/hudson` en el workspace, rama `main` (`4d129d0` Merge fix-bundle-module-launch-crash).
2. Fork GitHub: [https://github.com/horacioeps/hudson](https://github.com/horacioeps/hudson).
   - `origin` → horacioeps/hudson
   - `upstream` → mannasdev/hudson
3. Xcode 26.6 en `/Applications/Xcode.app`. El `xcode-select` global sigue en Command Line Tools (hace falta `sudo` para cambiarlo); los builds usaron `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Swift 6.3.3, target `arm64-apple-macosx26.0`.
4. Compilación release:
   - CLI: `.build/release/hudson` (Mach-O 64-bit arm64, ~9 MB). `hudson --help` OK.
   - App: `./Scripts/package-app.sh release` → `dist/Hudson.app` (unsigned, v0.1.0). `HUDSON_OAUTH_CLIENT_SECRET` no estaba; el login será BYO Google credentials.
5. Copia instalable: `~/Applications/Hudson.app` (ad-hoc codesign).
6. Rules alwaysApply: `.cursor/rules/local-clone-siempre-push.mdc`, `.cursor/rules/horacio-sesiones-historico.mdc`.
7. `HISTORICO.md` + enlace en README.

## Cómo abrir

- App: `open ~/Applications/Hudson.app` o `swift run HudsonApp --demo` (buzón sintético).
- CLI: `.build/release/hudson --help`
- Requiere macOS 15+ y Apple silicon.

## Remotos

```
origin    https://github.com/horacioeps/hudson.git
upstream  https://github.com/mannasdev/hudson.git
```

---

## Pedido (16:14)

Para añadir las cuentas de email, extraer esa info de Outlook for Mac.

## Hecho

Outlook (perfil `Main Profile`) tiene 2 cuentas en `ProfilePreferences.plist`:

- `horacio.eps@gmail.com` — conector Google (`InternetGoogle`)
- `horacio@horacio-ps.com` — IMAP genérico (`InternetMailIMAP`)

Office ActivationEmail extra: `hperez@ucam.edu` (no aparece como cuenta de correo en el perfil).

No se copiaron tokens ni contraseñas (Keychain / `Outlook.sqlite` / `HxStore`). Hudson es solo Gmail API + OAuth propio: Outlook no puede ceder la sesión. IMAP no entra en Hudson. Alta: Sign in with Google / `hudson auth` con la Gmail.

---

## Pedido (16:26)

Lanza Hudson.

## Hecho

`open ~/Applications/Hudson.app` — proceso `HudsonApp` (pid 90054).
