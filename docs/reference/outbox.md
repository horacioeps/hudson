# Outbox

`Sources/Outbox/` — five files that turn a composed message into RFC 5322 bytes
and get those bytes to Gmail exactly once. Depends on `GmailKit` (for the
`SentMessage`/`SendTransport` shapes) and `Store` (for the `send_jobs` durable
queue).

The hard problem here is not building MIME. It is that **Gmail's send API has
no idempotency token**, so if the process dies between "the network call may
have reached Gmail" and "we recorded that it did", only Hudson can decide
whether the message was sent. Getting that wrong means either a lost email or
a duplicate one.

| File | Role |
|---|---|
| `OutboxMessage.swift` | The compose input value type |
| `MimeBuilder.swift` | `OutboxMessage` → RFC 5322 bytes |
| `ReplyBuilder.swift` | Assembles a reply's threading triple from the local thread |
| `SubjectNormalization.swift` | `Re:` prefix collapsing |
| `SendService.swift` | The durable send state machine |

## OutboxMessage

```swift
public struct OutboxMessage: Sendable, Equatable {
    public let from: String
    public let to: [String], cc: [String], bcc: [String]
    public let subject: String
    public let bodyText: String
    public let bodyHTML: String?
    public let attachments: [Attachment]
    public let inReplyTo: String?      // parent's Message-ID
    public let references: [String]    // the accumulated chain
    public let threadID: String?       // Gmail's thread id — not a MIME header
}

public struct Attachment: Sendable, Equatable {
    public let filename: String, mimeType: String
    public let data: Data
}
```

A plain value type with no Gmail or network knowledge. It carries what was
composed; `SendService` owns the `Message-ID` and persistence.

### The threading triple

Correct reply threading needs three things, and they come from different
places:

1. **Gmail's `threadId`** — `OutboxMessage.threadID`, passed to
   `sendRawMessage(_:threadID:)`. Not a MIME header.
2. **`In-Reply-To` + `References`** — real RFC 5322 headers. `References` is
   *accumulated*: the parent's own chain with the parent's `Message-ID`
   appended, so a deep reply chain still references the whole thread (RFC 5322
   §3.6.4), not just its immediate parent.
3. **A matching Subject** — normalized to exactly one `Re: `.

Setting `threadID: nil` on a reply **deliberately starts a new Gmail thread**
while `In-Reply-To`/`References` still point back. That is the edited-subject
case: threading requires the full triple, so a reply whose subject changed
omits the thread id.

## MimeBuilder

```swift
public enum MimeBuilder {
    public static let maxEncodedBytes = 35 * 1024 * 1024
    public static func build(_ message: OutboxMessage, messageID: String, date: Date) throws -> Data
}

public enum OutboxError: Error, Equatable {
    case tooLarge(encodedBytes: Int)
    case invalidHeaderValue(field: String)
}
```

Structure: `text/plain` + `text/html` as `multipart/alternative`; attachments
wrap that in `multipart/mixed`.

**Byte-deterministic** for a fixed `messageID` + `date`. No `Date()`, no
`UUID()`, no random boundaries anywhere — MIME part boundaries are derived
from `messageID` via SHA-256. That determinism is what makes the golden-file
tests in `Tests/OutboxTests/Golden/` possible at all.

**Header injection is a build-time error.** This builder writes header lines
without folding support, so a raw CR or LF inside a Subject/To/filename value
would not continue the same header — it would start an entirely new one the
caller never asked for (a stealth `Bcc:`, say). `invalidHeaderValue(field:)`
names which value failed.

**Size is validated at compose/enqueue time, never at fire time**, so an
oversized attachment fails while the user is still looking at the compose
window. The 35 MB cap (~25 MB of effective attachments after base64 inflation)
is measured against the fully built document. That is deliberately *not* the
HTTP request size: `sendRawMessage` base64url-encodes the whole document again
into a JSON `raw` field, so the wire payload runs ~4/3 of this. Bounding the
wire size here instead would silently shrink the attachment allowance well
below what the spec promises.

## ReplyBuilder

```swift
public func replyMessage(
    to threadID: String, account: String, database: HudsonDatabase,
    from: String, bodyText: String, bodyHTML: String? = nil, replyAll: Bool
) async throws -> OutboxMessage

public enum ReplyBuilderError: Error, Equatable {
    case emptyThread(threadID: String)
}
```

Assembles the full triple from what the thread's **newest** message actually
carries, never from caller-supplied guesses. `replyAll` controls whether the
original recipients land in `cc`; the sender's own address is dropped either
way.

A free function rather than a `SendService` method because it only reads and
returns a value — nothing is enqueued. The caller passes the result to
`SendService.enqueue`, exactly as it would a fresh compose.

It **always** threads. A caller that lets the user edit the Subject before
sending is the one who must decide to drop `threadID` — a compose-time
decision no pure builder can make.

```swift
SubjectNormalization.replySubject(from: "Re: Re: RE: Fwd: Lunch")
// → "Re: Fwd: Lunch"
```

Collapses however many `Re:` hops (and however many differently-localized
prefixes) precede it into exactly one.

## SendService

```swift
public actor SendService {
    public init(api: any SendTransport, database: HudsonDatabase, account: String)

    public func enqueue(_ message: OutboxMessage,
                        undoHold: Duration = .seconds(15),
                        now: Int64) async throws -> Int64
    public func cancel(jobID: Int64, now: Int64) async throws -> Bool
    @discardableResult
    public func flushOnce(now: Int64) async throws -> Int
}

public protocol SendTransport: Sendable {
    func sendRawMessage(_ rawMIME: Data, threadID: String?) async throws -> SentMessage
    func findSentMessageID(rfc822MessageID: String) async throws -> String?
}

extension GmailClient: SendTransport {}
```

An `actor` with an explicit single-flight guard — two overlapping `flushOnce`
calls could otherwise interleave at an `await` and both drive the same job.

### The state machine

```
enqueue ──► pending / held ──► in_flight ──► sent
                  │                 │
              cancel()          probe on restart
              (undo-send)       hit → sent
                                miss → stay in_flight, re-probe next pass
```

### The dedup invariant

Three moves, and each one matters:

**1. Mint the `Message-ID` at enqueue.** `enqueue` generates a UUID-based RFC
5322 `Message-ID`, bakes it into the MIME, *and* persists it on the job row.
One call, one string, both places — so a message sent before a crash can be
recognized after it. The domain is the sender's own when parseable, falling
back to `hudson.local`.

**2. Commit `in_flight` before the wire.** `flushOnce` awaits
`markSendInFlight` — a real SQLite commit — *before* calling `sendRawMessage`.
Any job the network call might have delivered is therefore already durably
`in_flight`, never still `pending` where a naive retry would resend it.

**3. Probe on restart; never blind-resend.** For every job stranded
`in_flight`, search Sent for its `Message-ID`:

- **hit** → the message reached Gmail. Mark it `sent`. Not resent.
- **miss** → *not proof of non-delivery.* Gmail's search index lags a real
  send, so the job is left `in_flight` and re-probed next pass. A blind resend
  on a fast miss right after a crash is the one way this protocol could
  double-deliver.
- **probe throws** → rethrow and leave it for the next pass. We simply do not
  know yet, and guessing is exactly what the protocol forbids.

If a send itself throws, the job is already durably `in_flight`, so the pass
**stops** rather than continuing. The probe path is the only thing allowed to
decide that job's fate. Every job not yet reached stays `pending` and retries
cleanly, so a single transient failure strands at most the one job whose wire
call was already committed to.

### Undo-send

`enqueue` computes `hold_until = now + undoHold` (15 s by default). A job past
its hold is claimable by `flushOnce`; `cancel(jobID:now:)` deletes it while it
is still inside the window and has not gone `in_flight`. The precondition
lives in `Store.cancelSend`, which refuses once the send may be in motion.

## Usage

```swift
let service = SendService(api: client, database: db, account: email)
let now = Int64(Date().timeIntervalSince1970 * 1000)

// fresh compose
let job = try await service.enqueue(
    OutboxMessage(from: me, to: ["a@example.com"],
                  subject: "Hi", bodyText: "Hello"),
    now: now)

// or a reply
let reply = try await replyMessage(
    to: threadID, account: email, database: db,
    from: me, bodyText: "Sounds good", replyAll: false)
try await service.enqueue(reply, now: now)

// later, on the background loop
try await service.flushOnce(now: now)
```

`hudson send` / `hudson reply` do this from the CLI; `ComposerModel` +
`SendBootstrap` do it in the app.

## Tests

`Tests/OutboxTests/` — `MimeBuilderTests` (incl. golden-file byte compares
against `Golden/`), `ReplyBuilderTests`, `SubjectNormalizationTests`,
`SendServiceTests` (the crash/probe paths).

## Related

- [Store](store.md) — the `send_jobs` table and its API
- [GmailKit](gmailkit.md) — `sendRawMessage`, `findSentMessageID`
- [HudsonCLI](hudson-cli.md) — `hudson send`, `hudson reply`
