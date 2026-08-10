import Foundation

/// The single seam between GmailKit and the network. Production code uses
/// `URLSessionTransport`; tests inject `MockTransport`. Nothing else in the
/// package may touch URLSession directly.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The production transport: a thin, stateless wrapper over `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    /// Initializes the production HTTP transport using the shared URLSession.
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
