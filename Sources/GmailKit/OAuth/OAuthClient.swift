import Foundation

/// The user's own OAuth client, created in their Google Cloud project during
/// the guided setup. Google issues Desktop-app clients a "secret" that it
/// requires at the token endpoint but explicitly does not treat as
/// confidential for this client type (spec §6.1).
public struct OAuthCredentials: Sendable {
    public let clientID: String
    public let clientSecret: String

    /// Initializes OAuth credentials with the client ID and secret from Google Cloud.
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

    /// Initializes the OAuth client with credentials, a transport layer, and an optional time provider.
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
