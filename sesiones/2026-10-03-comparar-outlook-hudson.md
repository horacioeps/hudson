# 2026-10-03 — Comparar Outlook for Mac y Hudson

## Usuario

compara lado a lado outlook for mac, y hudson

## Agente

Comparación de producto (no benchmark local). Fuentes: README/docs de Hudson en este repo; Microsoft Support (Outlook for Mac features, Copilot, fin de soporte del Outlook legacy Mac / Exchange Online oct 2026); precios Microsoft 365 Personal.

Canvas al lado del chat: `canvases/outlook-vs-hudson.canvas.tsx` (fuera del repo GitHub; vive en el proyecto Cursor).

Tesis: no son el mismo tipo de app.

- **Outlook for Mac (actual):** PIM Microsoft 365 — correo, calendario, contactos, My Day, Teams. Cuentas Exchange, Outlook.com, Gmail, IMAP, POP, iCloud, Yahoo. Copilot con licencia y Connected Experiences. Cerrado, de pago (suscripción o compra). Multiplataforma. Pensado para IT (DLP, MIP, delegación). El cliente **legacy** deja de funcionar contra Exchange Online en octubre 2026.
- **Hudson:** cliente Gmail nativo Mac (SwiftUI + CLI, misma SQLite). Local-first, teclado (j/k/e/s/u, ⌘K), FTS local, triage optimista, IA BYO keys solo con invocación explícita, MIT, sin servidor ni telemetría. Solo Apple silicon / macOS 15+. Beta: snooze stub, sin auto-update, OAuth Google no verificado, backfill ~90 días. Sin calendario, sin IMAP/Exchange.

Cuándo Outlook: trabajo Exchange, agenda compartida, varios protocolos, móvil+PC.
Cuándo Hudson: Gmail en un Mac reciente, triage rápido, correo que no pasa por un servidor del cliente, IA con tu key.

Cierre: sesión + HISTORICO + push a `origin/main`.

## Usuario

vale tambien para mail ionos ???

## Agente

No. Hudson es Gmail API + OAuth (spec: “Gmail only… no IMAP”). IONOS es IMAP/SMTP. En Outlook de este Mac la cuenta IMAP `horacio@horacio-ps.com` encaja ahí; no entra en Hudson. Para IONOS: Outlook, Mail.app u otro cliente IMAP.
