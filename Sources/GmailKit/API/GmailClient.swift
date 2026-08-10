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
        var hasRetriedAuth = false

        for attempt in 1...Self.maxAttempts {
            var request = URLRequest(url: Self.baseURL.appending(path: path))
            let token = hasRetriedAuth
                ? try await session.forceRefresh()
                : try await session.validAccessToken()
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
                hasRetriedAuth = true  // retry once with a force-refreshed token
            case .auth, .network, .invalidRequest:
                throw error
            }
        }
        throw GmailError.network("Retry loop exited unexpectedly.")
    }
}
