# GmailKit

`Sources/GmailKit/` — everything that talks to Google: the OAuth flow, Keychain
storage, the typed Gmail API client, quota limiting, and error mapping. Has no
internal dependencies, so it can be reasoned about (and tested) on its own.

## Layout

```
GmailKit/
├── OAuth/        AccountSession, OAuthClient, PKCE, LoopbackServer,
│                 TokenSet, LLMKeyStore
├── TokenStore/   TokenStore protocol, Keychain + in-memory implementations
├── Transport/    HTTPTransport, GmailError, QuotaBucket
├── API/          GmailClient + endpoint extensions + decodable models
└── Support/      Log
```

## Auth

Hudson uses **BYO OAuth**: the user creates their own free Google Cloud OAuth
client, or uses the bundled shared Desktop client. Either way the flow is
PKCE + loopback, and tokens never leave the Mac.

```swift
let pkce = PKCE()
let state = randomState()

let oauth = OAuthClient(
    credentials: OAuthCredentials(clientID: id, clientSecret: secret),
    transport: URLSessionTransport())

let server = LoopbackServer()
let port = try await server.start()
let redirectURI = "http://127.0.0.1:\(port)"

let url = oauth.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce)
// open `url` in the browser…
let code = try await server.waitForCallback(expectedState: state)
let tokens = try await oauth.exchangeCode(code, redirectURI: redirectURI, pkce: pkce)
```

| Type | Role |
|---|---|
| `PKCE` | Generates the verifier; `PKCE.challenge(for:)` derives the S256 challenge |
| `randomState()` | CSRF state parameter |
| `LoopbackServer` | An `actor` HTTP listener on `127.0.0.1`; `start()` binds an ephemeral port, `waitForCallback` resolves the redirect, `stop()` tears it down |
| `OAuthClient` | `authorizationURL`, `exchangeCode`, `refresh` |
| `TokenSet` | `accessToken`, `refreshToken`, `expiresAt`; `isExpired(asOf:leeway:)` defaults to a 60s leeway |

Scope is a single constant:

```swift
GmailKit.oauthScope  // "https://www.googleapis.com/auth/gmail.modify"
```

`gmail.modify` covers read, label changes, and send. Hudson deliberately does
not request full-mailbox or delete scopes.

### AccountSession

```swift
public actor AccountSession {
    public func validAccessToken() async throws -> String
    public func forceRefresh() async throws -> String
}
```

Owns token lifecycle for one account: returns a live access token, refreshing
through the `TokenStore` when it has expired. An `actor` so concurrent callers
share one refresh instead of racing several.

### TokenStore

```swift
public protocol TokenStore: Sendable {
    func saveTokens(_ tokens: TokenSet, account: String) throws
    func tokens(account: String) throws -> TokenSet?
    func saveClientSecret(_ secret: String, account: String) throws
    func clientSecret(account: String) throws -> String?
    func deleteAll(account: String) throws
}
```

- `KeychainTokenStore` — production. Service `com.hudson.gmail`.
- `InMemoryTokenStore` — tests. **CI never touches the real Keychain** (spec
  §6.3); inject this one.

Both treat deleting a missing entry as a no-op rather than an error, which is
what lets `AppModel.disconnectAccount()` order its two deletes safely.

### LLMKeyStore

The same shape for LLM provider API keys, service `com.hudson.llm`. It lives
in GmailKit purely as the Keychain seam — this is the **only** reason
[AIKit](aikit.md) depends on GmailKit, and AIKit must never reach past it to
`GmailClient`.

```swift
public protocol LLMKeyStore: Sendable {
    func saveKey(_ key: String, provider: String) throws
    func key(provider: String) throws -> String?
    func deleteKey(provider: String) throws
}
```

`KeychainLLMKeyStore` and `InMemoryLLMKeyStore` implement it.

## GmailClient

```swift
let client = GmailClient(
    session: session,
    transport: URLSessionTransport(),
    quota: QuotaBucket())
```

Every call flows: **quota acquire → bearer token → request → error mapping →
bounded retry** (4 attempts). Adding an endpoint means adding a method; the
retry core is untouched.

| Method | Quota | Notes |
|---|---:|---|
| `getProfile()` | 1 | Also the source of the initial history cursor |
| `listMessages(pageToken:maxResults:query:)` | 5 | `query` is a Gmail `q` filter |
| `getMessage(id:format:)` | 20 | `format` is `"metadata"` or `"full"` |
| `listHistory(startHistoryID:pageToken:)` | 2 | 404 means the cursor expired |
| `listLabels()` | 1 | |
| `modify(id:addLabelIDs:removeLabelIDs:)` | 5 | Returns the updated message, incl. its new `historyId` |
| `batchModify(ids:addLabelIDs:removeLabelIDs:)` | 50 | |
| `sendRawMessage(_:threadID:)` | 100 | `threadID: nil` starts a new thread |
| `findSentMessageID(rfc822MessageID:)` | 5 | The restart dedup probe — searches Sent for `rfc822msgid:<id>` |

Costs are named constants in `GmailQuotaCost`.

`GmailMessage.extractContent()` pulls the HTML and plain-text parts out of the
MIME tree; `GmailMessage.attachments()` pulls attachment metadata.

## QuotaBucket

```swift
public actor QuotaBucket {
    public init(unitsPerMinute: Int = 5_500, interactiveReserve: Int = 1_000, …)
    public func acquire(cost: Int) async throws                       // .background
    public func acquire(cost: Int, class: QuotaClass) async throws
}
```

Client-side rolling-minute limiter. Google's ceiling is 6,000 units/min/user;
Hudson self-caps at 5,500 so a second device or the Gmail app itself cannot
push the account over.

**Two lanes share one window.** `.interactive` — foreground triage, someone
waiting on a star/archive/send — is admitted against the full budget and
drained ahead of anything queued as `.background`. `.background` — polling,
the multi-hour backfill, batch modify — is admitted only up to a reserved
sub-budget, so it can never saturate the window and make a foreground action
queue behind it.

Within a lane, waiters are served **strict FIFO** by a single drain task, so a
100-unit `messages.send` queued behind sustained 2-unit polling is not starved
by later cheaper requests that would otherwise fit sooner. A waiter whose task
is cancelled is removed and resumed with `CancellationError` promptly rather
than sitting until its grant.

`now` and `sleep` are injected, so tests run on a virtual clock.

## Errors

```swift
public enum GmailError: Error, Equatable {
    case auth(String)                                  // re-authorize needed
    case rateLimited(retryAfter: Double?)              // seconds, when Google sent one
    case network(String)                               // offline, DNS, TLS…
    case server(status: Int)                           // 5xx — safe to retry
    case invalidRequest(status: Int, message: String)  // retrying won't help
}

GmailError.from(status:data:retryAfterHeader:)   // the HTTP → error mapping
```

Callers switch on this; they never see raw `URLError`s or HTTP statuses. A 403
counts as rate limiting only when Google's error body says so
(`rateLimitExceeded` / `userRateLimitExceeded`); other 403s are permission
problems.

Two status codes carry specific meaning elsewhere:

- **404 from `listHistory`** means the history cursor expired — SyncEngine
  falls back to a full re-list. Scoped to `listHistory` alone; a 404 from
  `getMessage` is a vanished message, an unrelated event.
- **404 from `getMessage`** means the message is gone server-side. Backfill
  skips it silently; hydration tombstones it.

## Transport

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
```

`URLSessionTransport` in production; `MockTransport`
(`Tests/GmailKitTests/Support/`) in tests. This is the seam that keeps the
GmailKit suite hermetic — no test in this target makes a real network call.

## Logging

```swift
Log.transport, Log.auth, Log.sync   // os.Logger, subsystem "com.hudson.core"
```

**Never log message ids or content** (spec §9.1). Log lines carry fixed,
content-free labels and `privacy: .public` only on numeric statuses.

## Tests

`Tests/GmailKitTests/` — 18 files. `OAuthClientTests`, `PKCETests`,
`LoopbackServerTests`, `TokenStoreTests`, `QuotaBucketTests` +
`QuotaBucketPriorityTests`, `GmailClientTests`, and one file per endpoint
group.

## Related

- [SyncEngine](syncengine.md) — the main consumer, via the `GmailAPI` protocol
- [Outbox](outbox.md) — consumes `sendRawMessage`/`findSentMessageID` via `SendTransport`
- [HudsonCLI](hudson-cli.md) — `hudson auth` drives the OAuth flow
