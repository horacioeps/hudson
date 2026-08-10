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
