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
    private func get<Response: Decodable>(
        template: String, path: String, query: [URLQueryItem] = [], cost: Int
    ) async throws -> Response {
        try await quota.acquire(cost: cost)
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
            let token: String
            if needsForceRefresh {
                needsForceRefresh = false
                token = try await session.forceRefresh()
            } else {
                token = try await session.validAccessToken()
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await transport.send(request)
            Log.transport.info("GET \(template, privacy: .public) -> \(response.statusCode)")

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
