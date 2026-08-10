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
