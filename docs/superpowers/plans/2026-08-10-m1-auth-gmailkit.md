# M1 — Auth + GmailKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user can run `hudson auth`, complete the BYO-OAuth guided setup against their own Google Cloud project, and run `hudson profile` to see their live Gmail profile — with tokens in the Keychain and all Gmail traffic going through a quota-aware, retrying transport.

**Architecture:** `GmailKit` (library target) gets four seams — `HTTPTransport` (network boundary, mockable), `TokenStore` (secret persistence, mockable), `QuotaBucket` (rolling-minute rate limiting), and `OAuthClient`/`AccountSession` (token lifecycle). `hudson` (executable target) is a thin argument-parser CLI over GmailKit. Everything except the Keychain and the real network is exercised by `swift test`.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`import Testing`), swift-argument-parser (only external dependency), CryptoKit, Network.framework, Security.framework.

## Global Constraints

_(from `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` — every task inherits these)_

- Swift 6 language mode, macOS 15+ (`platforms: [.macOS(.v15)]`).
- External dependencies for M1: `swift-argument-parser` ONLY. No networking/keychain wrapper libraries.
- **Open-source readability bar:** doc comments (`///`) on every public type and method; descriptive names; no abbreviations like `mgr`/`svc`; files under ~200 lines; no dead code or debug prints.
- **Never-log list (spec §9.1):** Authorization headers, tokens, auth codes, client secrets, message content. Log only method, path template, status code.
- **No Google credentials in the repo or fixtures ever** (spec §6.1) — CI secret-scan enforces.
- OAuth scope is exactly `https://www.googleapis.com/auth/gmail.modify` (spec §6.2).
- Quota model (spec §4.5): 6,000 units/min/user ceiling, bucket capped at 5,500/min, `getProfile` = 1 unit.
- TDD: every task writes its failing test first. Commit after every green task.

---

### Task 1: Package scaffold + CI

**Files:**
- Create: `Package.swift`
- Create: `Sources/GmailKit/GmailKit.swift`
- Create: `Sources/HudsonCLI/HudsonCommand.swift`
- Create: `Tests/GmailKitTests/GmailKitTests.swift`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `GmailKit` library target + `hudson` executable target that later tasks add files to; CI that runs `swift test` and the secret scan on every push.

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hudson",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GmailKit", targets: ["GmailKit"]),
        .executable(name: "hudson", targets: ["HudsonCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "GmailKit"),
        .executableTarget(
            name: "HudsonCLI",
            dependencies: [
                "GmailKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GmailKitTests",
            dependencies: ["GmailKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: Write the placeholder library, CLI entry point, and a smoke test**

`Sources/GmailKit/GmailKit.swift`:

```swift
/// GmailKit is Hudson's typed Gmail REST client: OAuth, token storage,
/// quota-aware transport, and API models. It knows nothing about persistence
/// or UI — see `docs/superpowers/specs/2026-08-10-hudson-foundation-design.md` §2.
public enum GmailKit {
    /// The single OAuth scope Hudson requests (spec §6.2).
    public static let oauthScope = "https://www.googleapis.com/auth/gmail.modify"
}
```

`Sources/HudsonCLI/HudsonCommand.swift`:

```swift
import ArgumentParser

@main
struct HudsonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hudson",
        abstract: "A fast, open-source Gmail client for the Mac.",
        subcommands: []
    )
}
```

`Tests/GmailKitTests/GmailKitTests.swift` (also create an empty `Tests/GmailKitTests/Fixtures/.gitkeep` so the resource directory exists):

```swift
import Testing
@testable import GmailKit

@Test func oauthScopeIsGmailModify() {
    #expect(GmailKit.oauthScope == "https://www.googleapis.com/auth/gmail.modify")
}
```

- [ ] **Step 3: Verify build and test**

Run: `swift test`
Expected: 1 test passes.

- [ ] **Step 4: Write CI with secret scan**

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push: { branches: [main] }
  pull_request:
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Secret scan (no Google credentials in the repo, ever — spec §6.1)
        run: |
          ! grep -rE "GOCSPX-[A-Za-z0-9_-]{10,}|BEGIN( RSA)? PRIVATE KEY" \
              --exclude-dir=.git --exclude=ci.yml .
      - run: swift --version
      - run: swift test
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: SPM scaffold — GmailKit library, hudson CLI, CI with secret scan"
```

---

### Task 2: GmailError + HTTPTransport seam

**Files:**
- Create: `Sources/GmailKit/Transport/HTTPTransport.swift`
- Create: `Sources/GmailKit/Transport/GmailError.swift`
- Create: `Sources/GmailKit/Support/Log.swift`
- Create: `Tests/GmailKitTests/Support/MockTransport.swift`
- Test: `Tests/GmailKitTests/GmailErrorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`
  - `enum GmailError: Error, Equatable` with cases `auth(String)`, `rateLimited(retryAfter: Double?)`, `network(String)`, `server(status: Int)`, `invalidRequest(status: Int, message: String)` and `static func from(status: Int, data: Data, retryAfterHeader: String?) -> GmailError`
  - `actor MockTransport: HTTPTransport` (test helper) with `init(responses: [(Data, Int)])`, recorded `requests: [URLRequest]`, and `func recordedRequests() -> [URLRequest]`
  - `enum Log` with `static let transport: Logger`, `static let auth: Logger` (subsystem `"com.hudson.core"`)

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/GmailErrorTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

@Test func status401MapsToAuth() {
    let error = GmailError.from(status: 401, data: Data(), retryAfterHeader: nil)
    #expect(error == .auth("Gmail rejected the access token (HTTP 401)."))
}

@Test func status429MapsToRateLimitedWithRetryAfter() {
    let error = GmailError.from(status: 429, data: Data(), retryAfterHeader: "13")
    #expect(error == .rateLimited(retryAfter: 13))
}

@Test func rateLimitExceeded403MapsToRateLimited() {
    let body = #"{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}"#
    let error = GmailError.from(status: 403, data: Data(body.utf8), retryAfterHeader: nil)
    #expect(error == .rateLimited(retryAfter: nil))
}

@Test func status500MapsToServer() {
    #expect(GmailError.from(status: 500, data: Data(), retryAfterHeader: nil) == .server(status: 500))
}

@Test func status400CarriesGoogleMessage() {
    let body = #"{"error": {"message": "Invalid id value"}}"#
    let error = GmailError.from(status: 400, data: Data(body.utf8), retryAfterHeader: nil)
    #expect(error == .invalidRequest(status: 400, message: "Invalid id value"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GmailErrorTests`
Expected: FAIL — `GmailError` not defined.

- [ ] **Step 3: Implement**

`Sources/GmailKit/Transport/HTTPTransport.swift`:

```swift
import Foundation

/// The single seam between GmailKit and the network. Production code uses
/// `URLSessionTransport`; tests inject `MockTransport`. Nothing else in the
/// package may touch URLSession directly.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport: a thin, stateless wrapper over `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailError.network("Response was not HTTP.")
            }
            return (data, httpResponse)
        } catch let error as GmailError {
            throw error
        } catch {
            throw GmailError.network(error.localizedDescription)
        }
    }
}
```

`Sources/GmailKit/Transport/GmailError.swift`:

```swift
import Foundation

/// Every failure GmailKit surfaces, typed per spec §9. Callers switch on this;
/// they never see raw URLErrors or HTTP statuses.
public enum GmailError: Error, Equatable {
    /// The account needs to re-authorize (bad/expired/revoked credentials).
    case auth(String)
    /// Gmail asked us to slow down. `retryAfter` is seconds, when Google provided it.
    case rateLimited(retryAfter: Double?)
    /// Transport-level failure (offline, DNS, TLS…).
    case network(String)
    /// Gmail returned a 5xx; safe to retry with backoff.
    case server(status: Int)
    /// We sent something Gmail rejected; retrying the same request won't help.
    case invalidRequest(status: Int, message: String)

    /// Maps an HTTP response to a `GmailError`. A 403 counts as rate limiting
    /// only when Google's error body says so (`rateLimitExceeded` /
    /// `userRateLimitExceeded`); other 403s are permission problems.
    public static func from(status: Int, data: Data, retryAfterHeader: String?) -> GmailError {
        switch status {
        case 401:
            return .auth("Gmail rejected the access token (HTTP 401).")
        case 429:
            return .rateLimited(retryAfter: retryAfterHeader.flatMap(Double.init))
        case 403 where bodyIndicatesRateLimit(data):
            return .rateLimited(retryAfter: retryAfterHeader.flatMap(Double.init))
        case 500...:
            return .server(status: status)
        default:
            return .invalidRequest(status: status, message: googleErrorMessage(in: data))
        }
    }

    private static func bodyIndicatesRateLimit(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains("rateLimitExceeded") || body.contains("userRateLimitExceeded")
    }

    private static func googleErrorMessage(in data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        let decoded = try? JSONDecoder().decode(Envelope.self, from: data)
        return decoded?.error?.message ?? "Unexpected Gmail API response."
    }
}
```

`Sources/GmailKit/Support/Log.swift`:

```swift
import OSLog

/// Central loggers. Spec §9.1 hard rule: NEVER log Authorization headers,
/// tokens, auth codes, client secrets, or message content. Network logs carry
/// method, path template, and status code only. Dynamic values default to
/// `.private` unless explicitly safe.
public enum Log {
    public static let transport = Logger(subsystem: "com.hudson.core", category: "transport")
    public static let auth = Logger(subsystem: "com.hudson.core", category: "auth")
}
```

`Tests/GmailKitTests/Support/MockTransport.swift`:

```swift
import Foundation
@testable import GmailKit

/// Test transport: returns canned (body, status) pairs in order and records
/// every request so tests can assert on URLs, headers, and bodies.
actor MockTransport: HTTPTransport {
    private var responses: [(Data, Int)]
    private var requests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw GmailError.network("MockTransport ran out of stubbed responses.")
        }
        let (data, status) = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GmailErrorTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): typed GmailError, HTTPTransport seam, logging rules"
```

---

### Task 3: PKCE

**Files:**
- Create: `Sources/GmailKit/OAuth/PKCE.swift`
- Test: `Tests/GmailKitTests/PKCETests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct PKCE: Sendable` with `let verifier: String`, `let challenge: String`, `init()`, and `static func challenge(for verifier: String) -> String`; `func randomState() -> String` (free function in the same file).

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/PKCETests.swift`:

```swift
import Testing
@testable import GmailKit

@Test func verifierIsUnreservedAndLongEnough() {
    let pkce = PKCE()
    // RFC 7636 §4.1: 43–128 chars from [A-Za-z0-9-._~].
    #expect(pkce.verifier.count >= 43 && pkce.verifier.count <= 128)
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
}

@Test func challengeMatchesRFC7636TestVector() {
    // Appendix B of RFC 7636.
    let challenge = PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func stateIsUniquePerCall() {
    #expect(randomState() != randomState())
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PKCETests`
Expected: FAIL — `PKCE` not defined.

- [ ] **Step 3: Implement**

`Sources/GmailKit/OAuth/PKCE.swift`:

```swift
import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636), required by Google for installed
/// apps. A fresh `PKCE` value is generated per authorization attempt.
public struct PKCE: Sendable {
    /// High-entropy random string sent with the token exchange.
    public let verifier: String
    /// SHA-256(verifier), base64url-encoded — sent with the authorization URL.
    public let challenge: String

    public init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        self.verifier = Data(bytes).base64URLEncoded()
        self.challenge = Self.challenge(for: verifier)
    }

    /// The S256 code-challenge transform.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

/// Random `state` parameter tying the OAuth callback to this attempt (CSRF guard).
public func randomState() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64URLEncoded()
}

extension Data {
    /// Base64url without padding (RFC 4648 §5), as OAuth requires.
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PKCETests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): PKCE (RFC 7636) with test-vector coverage"
```

---

### Task 4: TokenSet + TokenStore (in-memory and Keychain)

**Files:**
- Create: `Sources/GmailKit/OAuth/TokenSet.swift`
- Create: `Sources/GmailKit/TokenStore/TokenStore.swift`
- Create: `Sources/GmailKit/TokenStore/InMemoryTokenStore.swift`
- Create: `Sources/GmailKit/TokenStore/KeychainTokenStore.swift`
- Test: `Tests/GmailKitTests/TokenStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct TokenSet: Codable, Equatable, Sendable` — `let accessToken: String`, `let refreshToken: String`, `let expiresAt: Date`, `init(accessToken:refreshToken:expiresAt:)`, `func isExpired(asOf now: Date, leeway: TimeInterval = 60) -> Bool`
  - `protocol TokenStore: Sendable` — `func saveTokens(_ tokens: TokenSet, account: String) throws`, `func tokens(account: String) throws -> TokenSet?`, `func saveClientSecret(_ secret: String, account: String) throws`, `func clientSecret(account: String) throws -> String?`, `func deleteAll(account: String) throws`
  - `final class InMemoryTokenStore: TokenStore` (thread-safe via `Mutex`) — used by all tests; the real Keychain is never touched by CI (spec §6.3)
  - `struct KeychainTokenStore: TokenStore` — generic-password items, service `"com.hudson.gmail"`, account keys `"<email>#tokens"` / `"<email>#client-secret"`

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/TokenStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

@Test func roundTripsTokensAndSecret() throws {
    let store = InMemoryTokenStore()
    let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture)
    try store.saveTokens(tokens, account: "a@example.com")
    try store.saveClientSecret("shh", account: "a@example.com")
    #expect(try store.tokens(account: "a@example.com") == tokens)
    #expect(try store.clientSecret(account: "a@example.com") == "shh")
}

@Test func unknownAccountReturnsNil() throws {
    #expect(try InMemoryTokenStore().tokens(account: "nobody@example.com") == nil)
}

@Test func deleteAllRemovesEverythingForOneAccountOnly() throws {
    let store = InMemoryTokenStore()
    let tokens = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture)
    try store.saveTokens(tokens, account: "a@example.com")
    try store.saveTokens(tokens, account: "b@example.com")
    try store.deleteAll(account: "a@example.com")
    #expect(try store.tokens(account: "a@example.com") == nil)
    #expect(try store.tokens(account: "b@example.com") == tokens)
}

@Test func expiryUsesLeeway() {
    let tokens = TokenSet(
        accessToken: "at", refreshToken: "rt",
        expiresAt: Date(timeIntervalSince1970: 1_000))
    // 30s before expiry is "expired" under the default 60s leeway.
    #expect(tokens.isExpired(asOf: Date(timeIntervalSince1970: 970)))
    #expect(!tokens.isExpired(asOf: Date(timeIntervalSince1970: 900)))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TokenStoreTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement**

`Sources/GmailKit/OAuth/TokenSet.swift`:

```swift
import Foundation

/// One account's OAuth tokens. Persisted only via a `TokenStore` — never to
/// disk, config files, or logs (spec §9.1).
public struct TokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the access token is expired or will be within `leeway`
    /// seconds — refresh slightly early rather than race the deadline.
    public func isExpired(asOf now: Date, leeway: TimeInterval = 60) -> Bool {
        now >= expiresAt.addingTimeInterval(-leeway)
    }
}
```

`Sources/GmailKit/TokenStore/TokenStore.swift`:

```swift
/// Persistence seam for secrets: OAuth tokens and the user's BYO client
/// secret. Production uses `KeychainTokenStore`; tests use
/// `InMemoryTokenStore` so CI never touches a real keychain (spec §6.3).
public protocol TokenStore: Sendable {
    func saveTokens(_ tokens: TokenSet, account: String) throws
    func tokens(account: String) throws -> TokenSet?
    func saveClientSecret(_ secret: String, account: String) throws
    func clientSecret(account: String) throws -> String?
    func deleteAll(account: String) throws
}
```

`Sources/GmailKit/TokenStore/InMemoryTokenStore.swift`:

```swift
import Synchronization

/// Test/preview implementation of `TokenStore`. Thread-safe, non-persistent.
public final class InMemoryTokenStore: TokenStore {
    private struct Entry { var tokens: TokenSet?; var clientSecret: String? }
    private let entries = Mutex<[String: Entry]>([:])

    public init() {}

    public func saveTokens(_ tokens: TokenSet, account: String) throws {
        entries.withLock { $0[account, default: Entry()].tokens = tokens }
    }

    public func tokens(account: String) throws -> TokenSet? {
        entries.withLock { $0[account]?.tokens }
    }

    public func saveClientSecret(_ secret: String, account: String) throws {
        entries.withLock { $0[account, default: Entry()].clientSecret = secret }
    }

    public func clientSecret(account: String) throws -> String? {
        entries.withLock { $0[account]?.clientSecret }
    }

    public func deleteAll(account: String) throws {
        entries.withLock { $0[account] = nil }
    }
}
```

`Sources/GmailKit/TokenStore/KeychainTokenStore.swift`:

```swift
import Foundation
import Security

/// Keychain-backed `TokenStore` using generic-password items in the login
/// keychain (the data-protection keychain needs entitlements a bare CLI can't
/// hold — spec §6.3). Items are ACL-bound to the CLI's signing identity;
/// `Scripts/sign-cli.sh` keeps that identity stable across rebuilds.
public struct KeychainTokenStore: TokenStore {
    /// Keychain `kSecAttrService` for every Hudson item.
    public static let service = "com.hudson.gmail"

    public init() {}

    public func saveTokens(_ tokens: TokenSet, account: String) throws {
        try write(try JSONEncoder().encode(tokens), key: "\(account)#tokens")
    }

    public func tokens(account: String) throws -> TokenSet? {
        try read(key: "\(account)#tokens").map { try JSONDecoder().decode(TokenSet.self, from: $0) }
    }

    public func saveClientSecret(_ secret: String, account: String) throws {
        try write(Data(secret.utf8), key: "\(account)#client-secret")
    }

    public func clientSecret(account: String) throws -> String? {
        try read(key: "\(account)#client-secret").map { String(decoding: $0, as: UTF8.self) }
    }

    public func deleteAll(account: String) throws {
        for key in ["\(account)#tokens", "\(account)#client-secret"] {
            let query = baseQuery(key: key)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
        }
    }

    // MARK: - Keychain plumbing

    private func baseQuery(key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: key,
        ]
    }

    private func write(_ data: Data, key: String) throws {
        var query = baseQuery(key: key)
        let update = [kSecValueData: data] as [CFString: Any]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    private func read(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data)
        case errSecItemNotFound: return nil
        default: throw keychainError(status)
        }
    }

    private func keychainError(_ status: OSStatus) -> GmailError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .auth("Keychain operation failed: \(message)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TokenStoreTests`
Expected: 4 tests pass. (KeychainTokenStore compiles but is exercised manually in Task 9 — CI never touches the real keychain.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): TokenSet + TokenStore with in-memory and Keychain backends"
```

---

### Task 5: QuotaBucket

**Files:**
- Create: `Sources/GmailKit/Transport/QuotaBucket.swift`
- Test: `Tests/GmailKitTests/QuotaBucketTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum GmailQuotaCost` — `static let getProfile = 1`, `messagesGet = 20`, `messagesList = 5`, `messagesSend = 100`, `historyList = 2` (full table from spec §4.5, defined now so later milestones just use it)
  - `actor QuotaBucket` — `init(unitsPerMinute: Int = 5_500, now: @escaping @Sendable () -> Date = { Date() }, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })` and `func acquire(cost: Int) async throws`

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/QuotaBucketTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

/// Drives QuotaBucket with a manual clock: `sleep` advances virtual time
/// instead of really sleeping, so tests are instant and deterministic.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 0)
    private(set) var totalSlept: TimeInterval = 0

    var now: Date { lock.withLock { time } }
    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            time += seconds
            totalSlept += seconds
        }
    }
}

@Test func underCapacityNeverSleeps() async throws {
    let clock = VirtualClock()
    let bucket = QuotaBucket(unitsPerMinute: 100, now: { clock.now }, sleep: { clock.sleep($0) })
    for _ in 0..<5 { try await bucket.acquire(cost: 20) }  // exactly 100 units
    #expect(clock.totalSlept == 0)
}

@Test func overCapacityWaitsForWindowToRoll() async throws {
    let clock = VirtualClock()
    let bucket = QuotaBucket(unitsPerMinute: 100, now: { clock.now }, sleep: { clock.sleep($0) })
    for _ in 0..<5 { try await bucket.acquire(cost: 20) }
    try await bucket.acquire(cost: 20)  // 101st+ unit must wait ~60s for the window
    #expect(clock.totalSlept >= 59 && clock.totalSlept <= 61)
}

@Test func oversizedCostIsRejected() async {
    let bucket = QuotaBucket(unitsPerMinute: 100)
    await #expect(throws: GmailError.self) {
        try await bucket.acquire(cost: 101)  // can never fit; must throw, not hang
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QuotaBucketTests`
Expected: FAIL — `QuotaBucket` not defined.

- [ ] **Step 3: Implement**

`Sources/GmailKit/Transport/QuotaBucket.swift`:

```swift
import Foundation

/// Gmail quota-unit costs per API method (spec §4.5, May-2026 pricing).
/// Defined for all of Hudson now; M1 only spends `getProfile`.
public enum GmailQuotaCost {
    public static let getProfile = 1
    public static let historyList = 2
    public static let messagesList = 5
    public static let messagesGet = 20
    public static let messagesSend = 100
}

/// Client-side rolling-minute rate limiter. Google enforces 6,000 quota
/// units/min/user (spec §4.5); we cap ourselves at 5,500 by default so a
/// second device or the Gmail app itself never pushes the account over.
/// `now`/`sleep` are injected so tests run on a virtual clock.
public actor QuotaBucket {
    private let unitsPerMinute: Int
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// Spends inside the current 60s window, oldest first.
    private var spends: [(date: Date, cost: Int)] = []

    public init(
        unitsPerMinute: Int = 5_500,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.unitsPerMinute = unitsPerMinute
        self.now = now
        self.sleep = sleep
    }

    /// Waits until `cost` units fit in the rolling window, then records them.
    public func acquire(cost: Int) async throws {
        guard cost <= unitsPerMinute else {
            throw GmailError.invalidRequest(
                status: 0,
                message: "Quota cost \(cost) exceeds the per-minute budget of \(unitsPerMinute).")
        }
        while true {
            pruneExpiredSpends()
            let spent = spends.reduce(0) { $0 + $1.cost }
            if spent + cost <= unitsPerMinute {
                spends.append((now(), cost))
                return
            }
            // Sleep until the oldest spend leaves the window, then re-check.
            let oldest = spends[0].date
            let waitSeconds = max(60 - now().timeIntervalSince(oldest), 0.05)
            try await sleep(waitSeconds)
        }
    }

    private func pruneExpiredSpends() {
        let cutoff = now().addingTimeInterval(-60)
        spends.removeAll { $0.date <= cutoff }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QuotaBucketTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): rolling-minute QuotaBucket with virtual-clock tests"
```

---

### Task 6: OAuthClient (authorize URL, code exchange, refresh)

**Files:**
- Create: `Sources/GmailKit/OAuth/OAuthClient.swift`
- Create: `Tests/GmailKitTests/Fixtures/token_success.json`
- Create: `Tests/GmailKitTests/Fixtures/token_invalid_grant.json`
- Test: `Tests/GmailKitTests/OAuthClientTests.swift`

**Interfaces:**
- Consumes: `PKCE`, `TokenSet`, `HTTPTransport`, `MockTransport`, `GmailError`, `GmailKit.oauthScope`.
- Produces:
  - `struct OAuthCredentials: Sendable` — `let clientID: String`, `let clientSecret: String`, memberwise `init`
  - `struct OAuthClient: Sendable` — `init(credentials: OAuthCredentials, transport: any HTTPTransport, now: @escaping @Sendable () -> Date = { Date() })`;
    `func authorizationURL(redirectURI: String, state: String, pkce: PKCE) -> URL`;
    `func exchangeCode(_ code: String, verifier: String, redirectURI: String) async throws -> TokenSet`;
    `func refresh(_ tokens: TokenSet) async throws -> TokenSet` — throws `GmailError.auth("invalid_grant: …")` on revoked/expired grants (the CLI adds the Testing-status hint, Task 9)

- [ ] **Step 1: Write the fixtures**

`Tests/GmailKitTests/Fixtures/token_success.json`:

```json
{
  "access_token": "test-access-token",
  "expires_in": 3599,
  "refresh_token": "test-refresh-token",
  "scope": "https://www.googleapis.com/auth/gmail.modify",
  "token_type": "Bearer"
}
```

`Tests/GmailKitTests/Fixtures/token_invalid_grant.json`:

```json
{
  "error": "invalid_grant",
  "error_description": "Token has been expired or revoked."
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/GmailKitTests/OAuthClientTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private let credentials = OAuthCredentials(clientID: "test-client-id", clientSecret: "test-client-secret")

@Test func authorizationURLCarriesAllRequiredParameters() {
    let client = OAuthClient(credentials: credentials, transport: MockTransport(responses: []))
    let pkce = PKCE()
    let url = client.authorizationURL(
        redirectURI: "http://127.0.0.1:49152/callback", state: "st4te", pkce: pkce)
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
    #expect(url.host() == "accounts.google.com")
    #expect(value("client_id") == "test-client-id")
    #expect(value("redirect_uri") == "http://127.0.0.1:49152/callback")
    #expect(value("response_type") == "code")
    #expect(value("scope") == GmailKit.oauthScope)
    #expect(value("state") == "st4te")
    #expect(value("code_challenge") == pkce.challenge)
    #expect(value("code_challenge_method") == "S256")
    #expect(value("access_type") == "offline")
}

@Test func exchangeCodePostsFormAndParsesTokens() async throws {
    let transport = MockTransport(responses: [(try fixture("token_success"), 200)])
    let start = Date(timeIntervalSince1970: 1_000)
    let client = OAuthClient(credentials: credentials, transport: transport, now: { start })
    let tokens = try await client.exchangeCode(
        "auth-code", verifier: "verifier123", redirectURI: "http://127.0.0.1:49152/callback")
    #expect(tokens.accessToken == "test-access-token")
    #expect(tokens.refreshToken == "test-refresh-token")
    #expect(tokens.expiresAt == start.addingTimeInterval(3599))

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host() == "oauth2.googleapis.com")
    #expect(request.httpMethod == "POST")
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    #expect(body.contains("grant_type=authorization_code"))
    #expect(body.contains("code_verifier=verifier123"))
    #expect(body.contains("client_secret=test-client-secret"))
}

@Test func refreshKeepsOldRefreshTokenWhenGoogleOmitsIt() async throws {
    // Google frequently omits refresh_token on refresh responses.
    let response = #"{"access_token": "new-at", "expires_in": 3599, "token_type": "Bearer"}"#
    let transport = MockTransport(responses: [(Data(response.utf8), 200)])
    let client = OAuthClient(credentials: credentials, transport: transport)
    let old = TokenSet(accessToken: "old-at", refreshToken: "keep-me", expiresAt: .distantPast)
    let refreshed = try await client.refresh(old)
    #expect(refreshed.accessToken == "new-at")
    #expect(refreshed.refreshToken == "keep-me")
}

@Test func invalidGrantSurfacesAsAuthError() async throws {
    let transport = MockTransport(responses: [(try fixture("token_invalid_grant"), 400)])
    let client = OAuthClient(credentials: credentials, transport: transport)
    let old = TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantPast)
    await #expect(throws: GmailError.auth("invalid_grant: Token has been expired or revoked.")) {
        _ = try await client.refresh(old)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter OAuthClientTests`
Expected: FAIL — `OAuthClient` not defined.

- [ ] **Step 4: Implement**

`Sources/GmailKit/OAuth/OAuthClient.swift`:

```swift
import Foundation

/// The user's own OAuth client, created in their Google Cloud project during
/// the guided setup. Google issues Desktop-app clients a "secret" that it
/// requires at the token endpoint but explicitly does not treat as
/// confidential for this client type (spec §6.1).
public struct OAuthCredentials: Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// Google OAuth 2.0 for installed apps: builds the authorization URL,
/// exchanges the callback code, and refreshes access tokens.
public struct OAuthClient: Sendable {
    private static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private let credentials: OAuthCredentials
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        credentials: OAuthCredentials,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    /// The URL the system browser opens. `access_type=offline` is what makes
    /// Google issue a refresh token.
    public func authorizationURL(redirectURI: String, state: String, pkce: PKCE) -> URL {
        var components = URLComponents(string: Self.authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GmailKit.oauthScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
        ]
        return components.url!
    }

    /// Exchanges the authorization code from the loopback callback for tokens.
    public func exchangeCode(
        _ code: String, verifier: String, redirectURI: String
    ) async throws -> TokenSet {
        try await requestTokens(form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ], previousRefreshToken: nil)
    }

    /// Trades the refresh token for a fresh access token. Google often omits
    /// `refresh_token` in the response; the existing one stays valid.
    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        try await requestTokens(form: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ], previousRefreshToken: tokens.refreshToken)
    }

    // MARK: - Token endpoint plumbing

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Double
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func requestTokens(
        form: [String: String], previousRefreshToken: String?
    ) async throws -> TokenSet {
        var fullForm = form
        fullForm["client_id"] = credentials.clientID
        fullForm["client_secret"] = credentials.clientSecret

        var request = URLRequest(url: URL(string: Self.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fullForm).utf8)

        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            if let failure = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) {
                let detail = failure.errorDescription ?? "no description"
                throw GmailError.auth("\(failure.error): \(detail)")
            }
            throw GmailError.from(status: response.statusCode, data: data, retryAfterHeader: nil)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = decoded.refreshToken ?? previousRefreshToken else {
            throw GmailError.auth(
                "Google returned no refresh token. In the OAuth consent screen, remove this "
                + "app's prior grant at myaccount.google.com/permissions and re-run `hudson auth`.")
        }
        return TokenSet(
            accessToken: decoded.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(decoded.expiresIn))
    }

    private func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter OAuthClientTests`
Expected: 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): OAuthClient — authorize URL, code exchange, refresh"
```

---

### Task 7: LoopbackServer (OAuth redirect listener)

**Files:**
- Create: `Sources/GmailKit/OAuth/LoopbackServer.swift`
- Test: `Tests/GmailKitTests/LoopbackServerTests.swift`

**Interfaces:**
- Consumes: `GmailError`.
- Produces: `actor LoopbackServer` —
  `func start() async throws -> UInt16` (binds `127.0.0.1` on an OS-assigned ephemeral port, returns the port);
  `func waitForCallback(expectedState: String, timeout: TimeInterval = 300) async throws -> String` (returns the authorization code; throws `GmailError.auth` on state mismatch, user denial, or timeout);
  `func stop()`.

- [ ] **Step 1: Write the failing tests**

`Tests/GmailKitTests/LoopbackServerTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

@Test func capturesCodeFromCallback() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    async let code = server.waitForCallback(expectedState: "expected-state", timeout: 10)
    // Simulate the browser redirect Google performs.
    let url = URL(string: "http://127.0.0.1:\(port)/callback?code=the-code&state=expected-state")!
    let (body, _) = try await URLSession.shared.data(from: url)

    #expect(try await code == "the-code")
    #expect(String(decoding: body, as: UTF8.self).contains("Hudson"))
    await server.stop()
}

@Test func rejectsMismatchedState() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    async let code = server.waitForCallback(expectedState: "expected-state", timeout: 10)
    let url = URL(string: "http://127.0.0.1:\(port)/callback?code=x&state=WRONG")!
    _ = try await URLSession.shared.data(from: url)

    await #expect(throws: GmailError.self) { _ = try await code }
    await server.stop()
}

@Test func surfacesUserDenial() async throws {
    let server = LoopbackServer()
    let port = try await server.start()

    async let code = server.waitForCallback(expectedState: "s", timeout: 10)
    let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=s")!
    _ = try await URLSession.shared.data(from: url)

    await #expect(throws: GmailError.auth("Google reported: access_denied")) {
        _ = try await code
    }
    await server.stop()
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoopbackServerTests`
Expected: FAIL — `LoopbackServer` not defined.

- [ ] **Step 3: Implement**

`Sources/GmailKit/OAuth/LoopbackServer.swift`:

```swift
import Foundation
import Network

/// One-shot HTTP listener for the OAuth redirect. Binds 127.0.0.1 ONLY (never
/// all interfaces — spec §6.2) on an OS-assigned ephemeral port, waits for
/// Google's `/callback` redirect, hands the user a tiny confirmation page,
/// and resolves with the authorization code.
public actor LoopbackServer {
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var expectedState = ""

    public init() {}

    /// Starts listening; returns the bound port for building the redirect URI.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.receiveRequest(on: connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: GmailError.network(
                        "Could not open the local OAuth listener: \(error)"))
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Suspends until Google redirects the browser back, then returns the
    /// authorization code. Verifies `state` (CSRF guard, spec §6.2).
    public func waitForCallback(
        expectedState: String, timeout: TimeInterval = 300
    ) async throws -> String {
        self.expectedState = expectedState
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.storeContinuation(continuation) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GmailError.auth("Timed out waiting for the browser sign-in to finish.")
            }
            defer { group.cancelAll() }
            guard let code = try await group.next() else {
                throw GmailError.auth("OAuth callback wait ended unexpectedly.")
            }
            return code
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Request handling

    private func storeContinuation(_ continuation: CheckedContinuation<String, Error>) {
        callbackContinuation = continuation
    }

    private nonisolated func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { await self.handle(requestLine: requestLine, connection: connection) }
        }
    }

    private func handle(requestLine: String, connection: NWConnection) {
        // Request line looks like: GET /callback?code=…&state=… HTTP/1.1
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard path.hasPrefix("/callback"),
              let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            respond(on: connection, body: "Not found.", status: "404 Not Found")
            return
        }
        let query = { (name: String) in
            components.queryItems?.first { $0.name == name }?.value
        }

        let outcome: Result<String, GmailError>
        if let error = query("error") {
            outcome = .failure(.auth("Google reported: \(error)"))
        } else if query("state") != expectedState {
            outcome = .failure(.auth("OAuth state mismatch — possible interception; aborting."))
        } else if let code = query("code") {
            outcome = .success(code)
        } else {
            outcome = .failure(.auth("Callback carried no authorization code."))
        }

        switch outcome {
        case .success(let code):
            respond(on: connection,
                    body: "<h1>Hudson is connected.</h1><p>You can close this tab.</p>",
                    status: "200 OK")
            callbackContinuation?.resume(returning: code)
        case .failure(let error):
            respond(on: connection,
                    body: "<h1>Sign-in failed.</h1><p>Return to the terminal for details.</p>",
                    status: "200 OK")
            callbackContinuation?.resume(throwing: error)
        }
        callbackContinuation = nil
    }

    private nonisolated func respond(on connection: NWConnection, body: String, status: String) {
        let html = "<!doctype html><meta charset=\"utf-8\"><title>Hudson</title>\(body)"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackServerTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): loopback OAuth redirect listener with state verification"
```

---

### Task 8: AccountSession + GmailClient.getProfile (retry + quota)

**Files:**
- Create: `Sources/GmailKit/OAuth/AccountSession.swift`
- Create: `Sources/GmailKit/API/GmailClient.swift`
- Create: `Sources/GmailKit/API/Models/Profile.swift`
- Create: `Tests/GmailKitTests/Fixtures/profile.json`
- Test: `Tests/GmailKitTests/AccountSessionTests.swift`
- Test: `Tests/GmailKitTests/GmailClientTests.swift`

**Interfaces:**
- Consumes: `OAuthClient`, `TokenStore`, `TokenSet`, `QuotaBucket`, `GmailQuotaCost`, `HTTPTransport`, `MockTransport`, `GmailError`, `Log`.
- Produces:
  - `actor AccountSession` — `init(account: String, oauth: OAuthClient, store: any TokenStore, now: @escaping @Sendable () -> Date = { Date() })`; `func validAccessToken() async throws -> String` (refreshes and persists when expired); `func forceRefresh() async throws -> String`
  - `struct Profile: Decodable, Equatable, Sendable` — `let emailAddress: String`, `let messagesTotal: Int`, `let threadsTotal: Int`, `let historyId: String`
  - `struct GmailClient: Sendable` — `init(session: AccountSession, transport: any HTTPTransport, quota: QuotaBucket, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) })`; `func getProfile() async throws -> Profile`
  - Retry policy (internal to `GmailClient.send`): up to 4 attempts; `rateLimited` waits `retryAfter ?? 2^attempt` seconds; `server` waits `2^attempt`; one `forceRefresh()` on the first `auth` failure; `invalidRequest` never retries.

- [ ] **Step 1: Write the fixture**

`Tests/GmailKitTests/Fixtures/profile.json`:

```json
{
  "emailAddress": "test-user@example.com",
  "messagesTotal": 42107,
  "threadsTotal": 18344,
  "historyId": "9876543"
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/GmailKitTests/AccountSessionTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

private let credentials = OAuthCredentials(clientID: "id", clientSecret: "secret")

@Test func freshTokenIsReturnedWithoutRefreshing() async throws {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "fresh", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@example.com")
    let transport = MockTransport(responses: [])  // any network call would throw
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(credentials: credentials, transport: transport),
        store: store)
    #expect(try await session.validAccessToken() == "fresh")
}

@Test func expiredTokenIsRefreshedAndPersisted() async throws {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "stale", refreshToken: "rt", expiresAt: .distantPast),
        account: "a@example.com")
    let refreshResponse = #"{"access_token": "renewed", "expires_in": 3599, "token_type": "Bearer"}"#
    let transport = MockTransport(responses: [(Data(refreshResponse.utf8), 200)])
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(credentials: credentials, transport: transport),
        store: store)
    #expect(try await session.validAccessToken() == "renewed")
    #expect(try store.tokens(account: "a@example.com")?.accessToken == "renewed")
}

@Test func missingTokensSurfaceAsNeedsAuth() async {
    let session = AccountSession(
        account: "nobody@example.com",
        oauth: OAuthClient(credentials: credentials, transport: MockTransport(responses: [])),
        store: InMemoryTokenStore())
    await #expect(throws: GmailError.auth("No stored tokens — run `hudson auth` first.")) {
        _ = try await session.validAccessToken()
    }
}
```

`Tests/GmailKitTests/GmailClientTests.swift`:

```swift
import Foundation
import Testing
@testable import GmailKit

private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
    return try Data(contentsOf: url)
}

private func makeClient(
    transport: MockTransport, sleeps: LockedBox<[Double]>? = nil
) throws -> GmailClient {
    let store = InMemoryTokenStore()
    try store.saveTokens(
        TokenSet(accessToken: "at", refreshToken: "rt", expiresAt: .distantFuture),
        account: "a@example.com")
    let session = AccountSession(
        account: "a@example.com",
        oauth: OAuthClient(
            credentials: OAuthCredentials(clientID: "id", clientSecret: "secret"),
            transport: transport),
        store: store)
    return GmailClient(
        session: session, transport: transport, quota: QuotaBucket(),
        sleep: { seconds in sleeps?.append(seconds) })
}

/// Tiny thread-safe accumulator for observing retry sleeps.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

extension LockedBox where Value == [Double] {
    func append(_ element: Double) { withLock { $0.append(element) } }
    var values: [Double] { withLock { $0 } }
}

@Test func getProfileDecodesAndAuthorizes() async throws {
    let transport = MockTransport(responses: [(try fixture("profile"), 200)])
    let client = try makeClient(transport: transport)
    let profile = try await client.getProfile()
    #expect(profile == Profile(
        emailAddress: "test-user@example.com", messagesTotal: 42107,
        threadsTotal: 18344, historyId: "9876543"))
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/profile")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer at")
}

@Test func rateLimitedRequestRetriesAfterWaiting() async throws {
    let rateLimitBody = #"{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}"#
    let transport = MockTransport(responses: [
        (Data(rateLimitBody.utf8), 429),
        (try fixture("profile"), 200),
    ])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport: transport, sleeps: sleeps)
    _ = try await client.getProfile()
    #expect(sleeps.values.count == 1)  // one backoff sleep between the two attempts
}

@Test func serverErrorsRetryThenSucceed() async throws {
    let transport = MockTransport(responses: [
        (Data(), 503),
        (try fixture("profile"), 200),
    ])
    let sleeps = LockedBox<[Double]>([])
    let client = try makeClient(transport: transport, sleeps: sleeps)
    let profile = try await client.getProfile()
    #expect(profile.emailAddress == "test-user@example.com")
}

@Test func invalidRequestNeverRetries() async throws {
    let transport = MockTransport(responses: [(Data(), 404)])
    let client = try makeClient(transport: transport)
    await #expect(throws: GmailError.self) { _ = try await client.getProfile() }
    #expect(await transport.recordedRequests().count == 1)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter AccountSessionTests && swift test --filter GmailClientTests`
Expected: FAIL — types not defined.

- [ ] **Step 4: Implement**

`Sources/GmailKit/OAuth/AccountSession.swift`:

```swift
import Foundation

/// Owns one account's token lifecycle: hands out a valid access token,
/// refreshing through `OAuthClient` and persisting via `TokenStore` when
/// needed. Actor isolation alone does not stop concurrent callers from
/// racing separate `OAuthClient.refresh` calls — `await oauth.refresh`
/// suspends, so another call can observe the same expired token before the
/// first refresh lands. Instead, an in-flight refresh is tracked in
/// `refreshTask`; concurrent callers that arrive while one is running all
/// await that same task rather than starting their own.
public actor AccountSession {
    private let account: String
    private let oauth: OAuthClient
    private let store: any TokenStore
    private let now: @Sendable () -> Date
    /// The currently in-flight refresh, if any — shared by concurrent callers.
    private var refreshTask: Task<String, Error>?

    public init(
        account: String,
        oauth: OAuthClient,
        store: any TokenStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.oauth = oauth
        self.store = store
        self.now = now
    }

    /// A currently-valid access token, refreshing first if it is (nearly) expired.
    public func validAccessToken() async throws -> String {
        guard let tokens = try store.tokens(account: account) else {
            throw GmailError.auth("No stored tokens — run `hudson auth` first.")
        }
        guard tokens.isExpired(asOf: now()) else {
            return tokens.accessToken
        }
        return try await refreshAndPersist(tokens)
    }

    /// Unconditionally refreshes — used once when Gmail rejects a token that
    /// looked valid locally (revocation, clock skew).
    public func forceRefresh() async throws -> String {
        guard let tokens = try store.tokens(account: account) else {
            throw GmailError.auth("No stored tokens — run `hudson auth` first.")
        }
        return try await refreshAndPersist(tokens)
    }

    /// Coalesces concurrent refreshes: the check for `refreshTask` and the
    /// assignment that follows happen with no `await` between them, so no
    /// other actor-isolated call can slip in and start a duplicate refresh.
    private func refreshAndPersist(_ tokens: TokenSet) async throws -> String {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task<String, Error> {
            let refreshed = try await self.oauth.refresh(tokens)
            try self.store.saveTokens(refreshed, account: self.account)
            Log.auth.info("Refreshed access token.")
            return refreshed.accessToken
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
```

`Sources/GmailKit/API/Models/Profile.swift`:

```swift
/// `users.getProfile` response. `historyId` is the sync cursor M2's backfill
/// records before it starts (spec §4.1).
public struct Profile: Decodable, Equatable, Sendable {
    public let emailAddress: String
    public let messagesTotal: Int
    public let threadsTotal: Int
    public let historyId: String

    public init(emailAddress: String, messagesTotal: Int, threadsTotal: Int, historyId: String) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }
}
```

`Sources/GmailKit/API/GmailClient.swift`:

```swift
import Foundation

/// Typed Gmail API surface. Every call flows: quota acquire → bearer token →
/// request → error mapping → bounded retry. M1 ships `getProfile`; later
/// milestones add methods without touching the retry core.
public struct GmailClient: Sendable {
    private static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/")!
    private static let maxAttempts = 4

    private let session: AccountSession
    private let transport: any HTTPTransport
    private let quota: QuotaBucket
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        session: AccountSession,
        transport: any HTTPTransport,
        quota: QuotaBucket,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.session = session
        self.transport = transport
        self.quota = quota
        self.sleep = sleep
    }

    /// The account's profile — also M2's source for the initial history cursor.
    public func getProfile() async throws -> Profile {
        try await get("users/me/profile", cost: GmailQuotaCost.getProfile)
    }

    // MARK: - Request core

    private func get<Response: Decodable>(_ path: String, cost: Int) async throws -> Response {
        try await quota.acquire(cost: cost)
        var hasRetriedAuth = false      // gates the auth-retry arm: only ever one
        var needsForceRefresh = false   // consumed at use, so exactly ONE force refresh

        for attempt in 1...Self.maxAttempts {
            var request = URLRequest(url: Self.baseURL.appending(path: path))
            let token: String
            if needsForceRefresh {
                needsForceRefresh = false
                token = try await session.forceRefresh()
            } else {
                token = try await session.validAccessToken()
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await transport.send(request)
            Log.transport.info("GET \(path, privacy: .public) -> \(response.statusCode)")

            if response.statusCode == 200 {
                return try JSONDecoder().decode(Response.self, from: data)
            }

            let error = GmailError.from(
                status: response.statusCode,
                data: data,
                retryAfterHeader: response.value(forHTTPHeaderField: "Retry-After"))
            guard attempt < Self.maxAttempts else { throw error }

            switch error {
            case .rateLimited(let retryAfter):
                try await sleep(retryAfter ?? pow(2, Double(attempt)))
            case .server:
                try await sleep(pow(2, Double(attempt)))
            case .auth where !hasRetriedAuth:
                hasRetriedAuth = true      // never a second auth retry
                needsForceRefresh = true   // next attempt force-refreshes, once
            case .auth, .network, .invalidRequest:
                throw error
            }
        }
        throw GmailError.network("Retry loop exited unexpectedly.")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test`
Expected: all tests pass (this task's 7 plus everything earlier).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(gmailkit): AccountSession + GmailClient with quota-aware bounded retry"
```

---

### Task 9: CLI — `hudson auth` wizard + `hudson profile` + signing script

**Files:**
- Create: `Sources/HudsonCLI/AccountsFile.swift`
- Create: `Sources/HudsonCLI/ConsoleInput.swift`
- Create: `Sources/HudsonCLI/AuthCommand.swift`
- Create: `Sources/HudsonCLI/ProfileCommand.swift`
- Modify: `Sources/HudsonCLI/HudsonCommand.swift` (register subcommands)
- Create: `Scripts/sign-cli.sh`

**Interfaces:**
- Consumes: everything from Tasks 2–8.
- Produces:
  - `struct StoredAccount: Codable` — `var email: String`, `var clientID: String`, `var consentedAt: Date` (client **secret** lives in the Keychain only; the accounts file holds nothing sensitive)
  - `enum AccountsFile` — `static func load() throws -> [StoredAccount]`, `static func save(_ accounts: [StoredAccount]) throws`, `static func primary() throws -> StoredAccount` (first account, or a `GmailError.auth` telling the user to run `hudson auth`); path `~/Library/Application Support/Hudson/accounts.json`
  - `hudson auth` / `hudson profile` working end-to-end against a real account

Note on the spec's "wizard reads back and verifies the publishing status" (§6.1): Google exposes **no API** for consent-screen publishing status, so the wizard verifies via an explicit operator confirmation step plus the stored `consentedAt` date, which powers the `invalid_grant`-within-8-days "still in Testing?" diagnostic. This is the implementable form of that requirement.

- [ ] **Step 1: Implement AccountsFile and ConsoleInput**

`Sources/HudsonCLI/AccountsFile.swift`:

```swift
import Foundation
import GmailKit

/// One connected Gmail account. Deliberately free of secrets: the client
/// secret and tokens live in the Keychain (spec §6.3). M2 migrates this
/// file into the GRDB `accounts` table.
struct StoredAccount: Codable {
    var email: String
    var clientID: String
    /// When the user granted consent — powers the "app still in Testing?"
    /// diagnostic when a refresh fails within ~7 days (spec §6.1).
    var consentedAt: Date
}

/// JSON persistence for connected accounts at
/// `~/Library/Application Support/Hudson/accounts.json`.
enum AccountsFile {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hudson/accounts.json")
    }

    static func load() throws -> [StoredAccount] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return try JSONDecoder().decode([StoredAccount].self, from: data)
    }

    static func save(_ accounts: [StoredAccount]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(accounts).write(to: url)
    }

    /// The account CLI commands operate on. Multi-account selection arrives
    /// with the M2 data model; M1 uses the first (only) account.
    static func primary() throws -> StoredAccount {
        guard let account = try load().first else {
            throw GmailError.auth("No account connected — run `hudson auth` first.")
        }
        return account
    }
}
```

`Sources/HudsonCLI/ConsoleInput.swift`:

```swift
import Foundation

/// Terminal input helpers for the auth wizard.
enum ConsoleInput {
    /// Prompts and reads one trimmed line; empty input re-prompts.
    static func line(prompt: String) -> String {
        while true {
            print(prompt, terminator: " ")
            if let raw = readLine(), !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                return raw.trimmingCharacters(in: .whitespaces)
            }
            print("A value is required.")
        }
    }

    /// Reads a line with terminal echo off (for the client secret), so the
    /// value never appears on screen or in terminal scrollback.
    static func secret(prompt: String) -> String {
        print(prompt, terminator: " ")
        var terminalState = termios()
        tcgetattr(STDIN_FILENO, &terminalState)
        let originalState = terminalState
        terminalState.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &terminalState)
        defer {
            var restored = originalState
            tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            print()
        }
        return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// y/N confirmation; defaults to no.
    static func confirm(prompt: String) -> Bool {
        print("\(prompt) [y/N]", terminator: " ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}
```

- [ ] **Step 2: Implement the auth wizard**

`Sources/HudsonCLI/AuthCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GmailKit

/// The BYO-OAuth guided setup (spec §6.1): walks the user through creating
/// their own Google Cloud OAuth client, then runs the browser flow and
/// stores credentials. This is the CLI ancestor of the designed onboarding.
struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Connect a Gmail account using your own Google Cloud OAuth client."
    )

    @Flag(help: "Skip the publishing-status confirmation (weekly re-auth warning applies).")
    var allowTesting = false

    func run() async throws {
        printGuidedSetup()

        if !allowTesting {
            let published = ConsoleInput.confirm(
                prompt: "Did you click PUBLISH APP (status shows “In production”)?")
            guard published else {
                print("""

                Please publish the app first — apps left in “Testing” get refresh tokens
                that expire every 7 days, which means re-connecting Hudson weekly.
                (Google Cloud Console → APIs & Services → OAuth consent screen → Publish app.
                Re-run `hudson auth` when done, or pass --allow-testing to proceed anyway.)
                """)
                return
            }
        }

        let clientID = ConsoleInput.line(prompt: "Paste your OAuth Client ID:")
        let clientSecret = ConsoleInput.secret(prompt: "Paste your OAuth Client Secret (hidden):")

        // Browser flow: loopback listener → system browser → code → tokens.
        let credentials = OAuthCredentials(clientID: clientID, clientSecret: clientSecret)
        let oauth = OAuthClient(credentials: credentials, transport: URLSessionTransport())
        let server = LoopbackServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let state = randomState()
        let pkce = PKCE()
        let url = oauth.authorizationURL(redirectURI: redirectURI, state: state, pkce: pkce)

        print("\nOpening your browser to sign in with Google…")
        print("(Google will show “Google hasn’t verified this app” — that’s expected for a")
        print("personal OAuth client. Click Advanced → “Go to <your app>” to continue.)\n")
        openInBrowser(url)

        let code = try await server.waitForCallback(expectedState: state)
        let tokens = try await oauth.exchangeCode(code, verifier: pkce.verifier, redirectURI: redirectURI)

        // Identify the account, then persist everything under its address.
        let profile = try await fetchProfile(credentials: credentials, tokens: tokens)
        let store = KeychainTokenStore()
        try store.saveTokens(tokens, account: profile.emailAddress)
        try store.saveClientSecret(clientSecret, account: profile.emailAddress)

        var accounts = try AccountsFile.load().filter { $0.email != profile.emailAddress }
        accounts.append(StoredAccount(
            email: profile.emailAddress, clientID: clientID, consentedAt: Date()))
        try AccountsFile.save(accounts)

        print("Connected \(profile.emailAddress) — \(profile.messagesTotal) messages.")
        print("Try: hudson profile")
    }

    private func printGuidedSetup() {
        print("""
        Hudson connects to Gmail through YOUR OWN free Google Cloud OAuth client —
        no fees, no third party in the loop. One-time setup (~5 minutes):

          1. Create a project:   https://console.cloud.google.com/projectcreate
             (any name, e.g. “hudson-mail”)
          2. Enable the Gmail API:
             https://console.cloud.google.com/apis/library/gmail.googleapis.com
          3. Configure the OAuth consent screen (APIs & Services → OAuth consent screen):
             User type: External. App name/email: anything. Scopes: none needed here.
          4. IMPORTANT — click “PUBLISH APP” so status reads “In production”.
             (Testing status = refresh tokens die every 7 days.)
             Google Workspace accounts may choose “Internal” instead — also fine.
          5. Create credentials (APIs & Services → Credentials → Create credentials →
             OAuth client ID): Application type “Desktop app”.
          6. Copy the Client ID and Client Secret below.
             (For Desktop clients Google itself says the secret is not confidential —
             pasting it here is safe; Hudson stores it in your Keychain.)

        """)
    }

    private func openInBrowser(_ url: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try? process.run()
    }

    private func fetchProfile(
        credentials: OAuthCredentials, tokens: TokenSet
    ) async throws -> Profile {
        // A one-shot session over an in-memory store: we don't know the email
        // (the Keychain key) until the first getProfile succeeds.
        let bootstrapStore = InMemoryTokenStore()
        try bootstrapStore.saveTokens(tokens, account: "bootstrap")
        let session = AccountSession(
            account: "bootstrap",
            oauth: OAuthClient(credentials: credentials, transport: URLSessionTransport()),
            store: bootstrapStore)
        let client = GmailClient(
            session: session, transport: URLSessionTransport(), quota: QuotaBucket())
        return try await client.getProfile()
    }
}
```

- [ ] **Step 3: Implement the profile command and register subcommands**

`Sources/HudsonCLI/ProfileCommand.swift`:

```swift
import ArgumentParser
import Foundation
import GmailKit

/// Smoke-test command: proves auth, refresh, quota, and the typed client work
/// end-to-end against the real API.
struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Show the connected Gmail account's profile."
    )

    func run() async throws {
        let account = try AccountsFile.primary()
        let store = KeychainTokenStore()
        guard let clientSecret = try store.clientSecret(account: account.email) else {
            throw GmailError.auth("Keychain has no client secret — run `hudson auth` again.")
        }
        let session = AccountSession(
            account: account.email,
            oauth: OAuthClient(
                credentials: OAuthCredentials(clientID: account.clientID, clientSecret: clientSecret),
                transport: URLSessionTransport()),
            store: store)
        let client = GmailClient(
            session: session, transport: URLSessionTransport(), quota: QuotaBucket())

        do {
            let profile = try await client.getProfile()
            print("Account:   \(profile.emailAddress)")
            print("Messages:  \(profile.messagesTotal)")
            print("Threads:   \(profile.threadsTotal)")
            print("History ID: \(profile.historyId)  (M2's backfill cursor)")
        } catch let error as GmailError {
            throw annotated(error, consentedAt: account.consentedAt)
        }
    }

    /// The spec-§6.1 heuristic: a dead refresh token within ~8 days of consent
    /// usually means the OAuth app was left in Testing status.
    private func annotated(_ error: GmailError, consentedAt: Date) -> GmailError {
        guard case .auth(let message) = error, message.contains("invalid_grant"),
              Date().timeIntervalSince(consentedAt) < 8 * 24 * 3600 else {
            return error
        }
        return .auth(message + """


        Your grant died within a week of setup — the OAuth app is probably still in
        “Testing” status, where refresh tokens expire every 7 days. Fix: Google Cloud
        Console → APIs & Services → OAuth consent screen → PUBLISH APP, then `hudson auth`.
        """)
    }
}
```

Modify `Sources/HudsonCLI/HudsonCommand.swift` — register both:

```swift
import ArgumentParser

@main
struct HudsonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hudson",
        abstract: "A fast, open-source Gmail client for the Mac.",
        subcommands: [AuthCommand.self, ProfileCommand.self]
    )
}
```

- [ ] **Step 4: Write the signing script**

`Scripts/sign-cli.sh` (then `chmod +x Scripts/sign-cli.sh`):

```bash
#!/usr/bin/env bash
# Signs the hudson CLI with a stable identity so Keychain ACLs survive
# rebuilds (spec §6.3). Without this, every `swift build` produces a
# different ad-hoc identity and the Keychain re-prompts on each run.
set -euo pipefail

BINARY="${1:-.build/debug/hudson}"
IDENTITY="${HUDSON_SIGN_IDENTITY:-hudson-dev}"

if [[ ! -f "$BINARY" ]]; then
    echo "error: $BINARY not found — run 'swift build' first" >&2
    exit 1
fi

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$BINARY"
    echo "Signed $BINARY with '$IDENTITY'."
else
    codesign --force --sign - "$BINARY"
    cat >&2 <<'EOF'
warning: no 'hudson-dev' code-signing identity found; used ad-hoc signing.
The Keychain will re-prompt after every rebuild. To fix (one time):
  Keychain Access → Certificate Assistant → Create a Certificate…
  Name: hudson-dev · Identity type: Self-Signed Root · Certificate type: Code Signing
Then re-run this script.
EOF
fi
```

- [ ] **Step 5: Build and verify compilation + tests**

Run: `swift build && swift test && ./Scripts/sign-cli.sh`
Expected: builds, all tests pass, binary signed (warning path is fine on CI-less dev machines without the cert).

- [ ] **Step 6: Manual end-to-end verification (requires the operator's real account — cannot be automated)**

Run: `.build/debug/hudson auth` and follow the wizard with a real Google account, then `.build/debug/hudson profile`.
Expected: browser round-trip completes, "Connected <email>" printed, `profile` shows live message/thread counts, and a second `profile` run does not re-prompt the Keychain.
Record the outcome (worked / what failed) in the task notes before committing.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(cli): hudson auth wizard + hudson profile with Testing-status diagnostic"
```

---

### Task 10: README (the open-source front door)

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: the working CLI from Task 9.
- Produces: the repo's public landing page.

- [ ] **Step 1: Write README.md**

```markdown
# Hudson

A fast, open-source, Mac-native Gmail client. Superhuman-class speed, AI on
your own API keys, no subscription, no server, no telemetry.

> **Status:** pre-alpha. The headless core is being built milestone by
> milestone ([spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md));
> the Mac app UI follows. Today you can authenticate and talk to Gmail from
> the CLI.

## Why

Superhuman costs $25–40/month. Slashy costs $25/month. Both are closed. Hudson
is the same class of product — keyboard-first triage, sub-100ms feel, AI
drafting/summarizing/search — built openly, for free, with your own Google
OAuth client and your own LLM API keys. Nothing between you and your mail.

## Try the foundation (CLI)

Requires macOS 15+ and Xcode 16+.

```bash
git clone https://github.com/hudson-mail/hudson && cd hudson
swift build
./Scripts/sign-cli.sh          # stable signing so the Keychain trusts rebuilds
.build/debug/hudson auth       # ~5-minute guided Google OAuth setup
.build/debug/hudson profile    # your live Gmail profile
```

`hudson auth` walks you through creating your **own** free Google Cloud OAuth
client — that's the trick that keeps Hudson free and unverified-fee-free
forever. Your tokens live in your Keychain. Nothing phones home.

## Roadmap

Foundation (headless, CLI-verified): auth → sync engine → triage mutations →
search & split inbox → send → snooze/send-later → AI (Anthropic +
OpenAI-compatible/local). Then: the SwiftUI app, designed by a real designer.
Details: [the spec](docs/superpowers/specs/2026-08-10-hudson-foundation-design.md).

## Contributing

The spec is the source of truth; every milestone lands with tests
(`swift test`). Readability is a feature — if something is hard to follow,
that's a bug worth filing.

## License

MIT (see LICENSE).
```

- [ ] **Step 2: Verify the quickstart commands are accurate**

Run each command from the README's Try section (skipping `auth` if already connected).
Expected: they work exactly as written.

- [ ] **Step 3: Commit**

```bash
git add README.md && git commit -m "docs: README — project intro, CLI quickstart, roadmap"
```

---

## Self-Review (completed at plan-writing time)

1. **Spec coverage (M1 slice):** wizard incl. publish-status handling (§6.1) → Task 9; client ID **and** secret collection (§6.1) → Task 9; PKCE + loopback with state + 127.0.0.1-only (§6.2) → Tasks 3, 7; single `gmail.modify` scope (§6.2) → Tasks 1, 6; TokenStore protocol + Keychain + in-memory for tests (§6.3) → Task 4; CLI signing (§6.3) → Task 9; quota bucket at 5,500/min with method costs (§4.5) → Task 5; typed errors (§9) → Task 2; retry/backoff honoring Retry-After (§4.5) → Task 8; never-log rules (§9.1) → Tasks 2, 8; CI secret scan (§6.1) → Task 1. Testing-status *detection* is implemented as explicit confirmation + `consentedAt` heuristic — deviation from "reads back the publishing status" documented in Task 9 (no Google API exists for it).
2. **Placeholder scan:** no TBDs; every code step contains complete code; no "similar to Task N".
3. **Type consistency:** `TokenSet(accessToken:refreshToken:expiresAt:)`, `TokenStore` method names, `GmailError` cases, `QuotaBucket.acquire(cost:)`, `AccountSession.validAccessToken()/forceRefresh()`, `Profile` fields, and `MockTransport(responses:)`/`recordedRequests()` are used with identical signatures across Tasks 4–9. `LockedBox` is defined in Task 8's test file where it is used.
```
