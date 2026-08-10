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

    /// Initializes a Gmail API client with session, transport, quota tracking, and optional sleep.
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
        try await get(template: "users/me/profile", path: "users/me/profile", cost: GmailQuotaCost.getProfile)
    }

    // MARK: - Request core

    /// template is what gets logged (never the actual path — ids in paths would violate spec §9.1); path is what gets requested.
    /// `internal` (not `private`) so extensions in other files within GmailKit — e.g. `MessageEndpoints`, added
    /// starting M2 — can add methods without touching this retry core, per the type's doc comment above.
    func get<Response: Decodable>(
        template: String, path: String, query: [URLQueryItem] = [], cost: Int
    ) async throws -> Response {
        let (data, _) = try await performNoBody(
            method: "GET", template: template, path: path, query: query, cost: cost)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// POST returning a decoded body (e.g. messages.modify → Message).
    /// `quotaClass` defaults to `.background`, the lane every pre-M3 caller
    /// belongs to; interactive callers (triage's modify/batchModify) pass
    /// `.interactive` explicitly.
    func post<Body: Encodable, Response: Decodable>(
        template: String, path: String, body: Body, cost: Int, class quotaClass: QuotaClass = .background
    ) async throws -> Response {
        let (data, _) = try await perform(
            method: "POST", template: template, path: path, body: body, cost: cost, class: quotaClass)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    /// POST with no meaningful response body — succeeds on 200 or 204
    /// (batchModify returns 204 with an empty body). The `get`/`post` decode
    /// path would throw trying to JSON-decode that empty body; this path
    /// must not. `quotaClass` defaults to `.background` — see `post` above.
    func postVoid<Body: Encodable>(
        template: String, path: String, body: Body, cost: Int, class quotaClass: QuotaClass = .background
    ) async throws {
        _ = try await perform(
            method: "POST", template: template, path: path, body: body, cost: cost, class: quotaClass)
    }

    /// Sentinel body type for GET's `performNoBody` — GET requests never
    /// send a JSON body, so this is never actually encoded (`perform`'s
    /// body branch is skipped when the value is `nil`).
    private struct NoBody: Encodable {}

    /// GET convenience over `perform`: GET requests never send a body, so
    /// callers don't have to spell out `Optional<Body>.none` themselves.
    /// Forwards into the generic `perform` rather than looping itself, so
    /// GET and POST share one attempt loop.
    private func performNoBody(
        method: String, template: String, path: String, query: [URLQueryItem] = [], cost: Int
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(
            method: method, template: template, path: path, query: query,
            body: Optional<NoBody>.none, cost: cost)
    }

    /// Shared attempt loop for `get`/`post`/`postVoid`: quota acquire →
    /// bearer token (one-force-refresh rule) → request → error mapping →
    /// bounded retry. Returns the final successful `(data, response)` on
    /// status 200 or 204, or throws. Callers that require a body (`get`,
    /// `post`) are responsible for handling an unexpected 204 themselves
    /// (JSON-decoding empty data throws there, which is what we want).
    /// `quotaClass` defaults to `.background`; `get` (and thus
    /// `performNoBody`) never overrides it — only `post`/`postVoid` callers
    /// that need the interactive lane (triage's modify/batchModify) do.
    private func perform<Body: Encodable>(
        method: String, template: String, path: String, query: [URLQueryItem] = [],
        body: Body?, cost: Int, class quotaClass: QuotaClass = .background
    ) async throws -> (Data, HTTPURLResponse) {
        try await quota.acquire(cost: cost, class: quotaClass)
        // `hasRetriedAuth` never resets — it gates the ONE-force-refresh rule.
        // `needsForceRefresh` is consumed on next use so only the attempt right
        // after an auth failure force-refreshes; later attempts (429/5xx) go
        // back to the normal valid-token path instead of force-refreshing again.
        var hasRetriedAuth = false
        var needsForceRefresh = false

        for attempt in 1...Self.maxAttempts {
            var urlComponents = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)
            if !query.isEmpty {
                guard let encodedQuery = Self.encodedQuery(query) else {
                    throw GmailError.invalidRequest(status: 0, message: "Failed to encode query parameters")
                }
                urlComponents?.percentEncodedQuery = encodedQuery
            }
            guard let url = urlComponents?.url else {
                throw GmailError.invalidRequest(status: 0, message: "Failed to build request URL")
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body {
                request.httpBody = try JSONEncoder().encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let token: String
            if needsForceRefresh {
                needsForceRefresh = false
                token = try await session.forceRefresh()
            } else {
                token = try await session.validAccessToken()
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await transport.send(request)
            Log.transport.info("\(method, privacy: .public) \(template, privacy: .public) -> \(response.statusCode)")

            if response.statusCode == 200 || response.statusCode == 204 {
                return (data, response)
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
                hasRetriedAuth = true  // retry once with a force-refreshed token
                needsForceRefresh = true
            case .auth, .network, .invalidRequest:
                throw error
            }
        }
        throw GmailError.network("Retry loop exited unexpectedly.")
    }

    // MARK: - Query encoding

    /// Encodes query items with proper percent-encoding. Crucially, "+" in values is encoded as "%2B"
    /// (not left raw), because Google's API parses raw "+" as spaces, breaking Gmail plus-addressing.
    static func encodedQuery(_ items: [URLQueryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let components = items.map { item -> String in
            let allowedCharacters = CharacterSet.urlQueryAllowed
                .subtracting(CharacterSet(charactersIn: "+&="))
            let encodedValue = item.value?
                .addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? ""
            return "\(item.name)=\(encodedValue)"
        }
        return components.joined(separator: "&")
    }
}
