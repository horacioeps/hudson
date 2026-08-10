import ArgumentParser
import Foundation
import GmailKit

/// Prints a `GmailError`'s message cleanly to stderr and returns
/// `ExitCode.failure` for the caller to throw. `GmailError` isn't
/// `LocalizedError`, so letting it reach ArgumentParser's default top-level
/// handler debug-prints it (`Error: auth("...\n...")`), which escapes
/// embedded newlines into one unreadable line — exactly where this CLI's
/// highest-value diagnostic lives (the §6.1 "still in Testing?" remediation
/// block). Commands catch `GmailError` themselves and route it through here
/// instead: `throw reportAndFail(error)`. ArgumentParser prints nothing
/// further for a thrown `ExitCode`, so the message above is the only thing
/// the user sees.
func reportAndFail(_ error: GmailError) -> Error {
    FileHandle.standardError.write(Data((error.cliMessage + "\n").utf8))
    return ExitCode.failure
}

extension GmailError {
    /// A plain, human-readable rendering for terminal display: the
    /// associated message for `.auth` (which may be multi-line, e.g. the
    /// Testing-status diagnostic), or a short description for every other
    /// case the auth/profile flows can also surface.
    var cliMessage: String {
        switch self {
        case .auth(let message):
            return message
        case .rateLimited(let retryAfter):
            guard let retryAfter else {
                return "Gmail rate-limited this request; try again shortly."
            }
            return "Gmail rate-limited this request; retry after \(Int(retryAfter))s."
        case .network(let message):
            return "Network error: \(message)"
        case .server(let status):
            return "Gmail server error (HTTP \(status)); try again shortly."
        case .invalidRequest(let status, let message):
            return "Gmail rejected the request (HTTP \(status)): \(message)"
        }
    }
}
