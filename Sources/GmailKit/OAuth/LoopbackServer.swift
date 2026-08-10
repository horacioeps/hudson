import Foundation
import Network

/// One-shot HTTP listener for the OAuth redirect. Binds 127.0.0.1 ONLY (never
/// all interfaces — spec §6.2) on an OS-assigned ephemeral port, waits for
/// Google's `/callback` redirect, hands the user a tiny confirmation page,
/// and resolves with the authorization code.
///
/// Each instance is one-shot: `start()` and `waitForCallback(...)` may each
/// be called exactly once. Create a fresh `LoopbackServer` per sign-in
/// attempt.
public actor LoopbackServer {
    /// Lifecycle of the single callback this instance ever resolves. There
    /// is exactly one path to `.finished`, and the continuation inside
    /// `.waiting` is resumed at most once — from `resolve(_:)`, which is the
    /// only place that touches it.
    ///
    /// `.delivered` exists because the HTTP callback can race
    /// `waitForCallback`'s registration: the browser may hit `/callback`
    /// before the caller's next line of Swift runs `waitForCallback`. When
    /// that happens the outcome is buffered here instead of being dropped,
    /// and handed back the moment the wait registers.
    private enum Wait {
        case idle
        case waiting(CheckedContinuation<String, Error>)
        case delivered(Result<String, GmailError>)
        case finished
    }

    private var listener: NWListener?
    private var hasStarted = false
    private var hasWaited = false
    private var wait: Wait = .idle
    private var expectedState = ""

    public init() {}

    /// Starts listening; returns the bound port for building the redirect URI.
    /// Throws if called more than once on the same instance.
    public func start() async throws -> UInt16 {
        guard !hasStarted else {
            throw GmailError.auth(
                "LoopbackServer.start() was already called; use a fresh instance per sign-in attempt.")
        }
        hasStarted = true

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
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: GmailError.network(
                            "The local OAuth listener became ready without a bound port."))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: GmailError.network(
                        "Could not open the local OAuth listener: \(error)"))
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: GmailError.network(
                        "The local OAuth listener was cancelled before it became ready."))
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    /// Suspends until Google redirects the browser back, then returns the
    /// authorization code. Verifies `state` (CSRF guard, spec §6.2).
    /// Throws `GmailError.auth` on state mismatch, user denial, a missing
    /// code, timeout, external cancellation, or `stop()` being called
    /// mid-wait. Throws if called more than once on the same instance.
    public func waitForCallback(
        expectedState: String, timeout: TimeInterval = 300
    ) async throws -> String {
        guard !hasWaited else {
            throw GmailError.auth(
                "LoopbackServer.waitForCallback() was already called; use a fresh instance per sign-in attempt.")
        }
        hasWaited = true
        self.expectedState = expectedState

        // The callback may already have arrived (and been buffered) before
        // we got here — resolve immediately rather than registering a wait
        // nothing will ever satisfy.
        if case .delivered(let result) = wait {
            wait = .finished
            return try result.get()
        }

        let timeoutTask = Task {
            // This closure is created inside an actor-isolated method, so it
            // inherits that isolation: after the sleep resumes we're back on
            // this actor's executor already, and `resolve` (also isolated)
            // can be called directly.
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled {
                resolve(.failure(.auth("Timed out waiting for the browser sign-in to finish.")))
            }
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                // Runs synchronously, still on this actor's executor, so
                // this is the true, race-free registration point.
                switch wait {
                case .delivered(let result):
                    wait = .finished
                    continuation.resume(with: result)
                case .idle:
                    wait = .waiting(continuation)
                case .waiting, .finished:
                    continuation.resume(throwing: GmailError.auth(
                        "LoopbackServer.waitForCallback() was already called; use a fresh instance per sign-in attempt."))
                }
            }
        } onCancel: {
            Task { await self.resolve(.failure(.auth("Sign-in wait was cancelled."))) }
        }
    }

    /// Stops the listener. If a call to `waitForCallback` is still pending,
    /// it is resumed with `GmailError.auth` rather than left suspended.
    public func stop() {
        listener?.cancel()
        listener = nil
        resolve(.failure(.auth("Sign-in cancelled.")))
    }

    // MARK: - Wait resolution

    /// Resumes the pending wait at most once. If nothing is waiting yet,
    /// the result is buffered as `.delivered` for `waitForCallback` to pick
    /// up when it registers. Idempotent once `.finished`.
    private func resolve(_ result: Result<String, GmailError>) {
        switch wait {
        case .idle:
            wait = .delivered(result)
        case .waiting(let continuation):
            wait = .finished
            continuation.resume(with: result)
        case .delivered, .finished:
            break
        }
    }

    // MARK: - Request handling

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
        case .success:
            respond(on: connection,
                    body: "<h1>Hudson is connected.</h1><p>You can close this tab.</p>",
                    status: "200 OK")
        case .failure:
            respond(on: connection,
                    body: "<h1>Sign-in failed.</h1><p>Return to the terminal for details.</p>",
                    status: "200 OK")
        }
        resolve(outcome)
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
