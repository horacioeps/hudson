import Foundation

/// Terminal input helpers for the auth wizard.
enum ConsoleInput {
    /// Prompts and reads one trimmed line; empty input re-prompts.
    /// End-of-file (Ctrl-D, or a stdin-less invocation) is treated as an
    /// explicit cancellation rather than re-prompting a channel that will
    /// never produce input.
    static func line(prompt: String) -> String {
        while true {
            print(prompt, terminator: " ")
            guard let raw = readLine() else {
                print("\nCancelled.")
                exit(0)
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            print("A value is required.")
        }
    }

    /// Reads a line with terminal echo off (for the client secret), so the
    /// value never appears on screen or in terminal scrollback.
    ///
    /// Fails closed: if stdin isn't a terminal, or the terminal's echo
    /// setting can't be verifiably read and disabled, this prints an
    /// explanation and exits rather than silently prompting in the clear.
    /// Echo is disabled with `TCSAFLUSH` so any type-ahead typed before the
    /// prompt (which would otherwise land on-screen) is discarded instead of
    /// echoed. A SIGINT/SIGTERM handler is installed for the duration of the
    /// echo-off window, because `defer` does not run when a signal kills the
    /// process under its default disposition — without the handler, Ctrl-C
    /// here would leave the terminal echo-less for the rest of the session.
    static func secret(prompt: String) -> String {
        guard isatty(STDIN_FILENO) != 0 else {
            failClosed(reason: "stdin is not a terminal")
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            failClosed(reason: "could not read the current terminal settings")
        }

        var muted = original
        muted.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &muted) == 0 else {
            failClosed(reason: "could not disable terminal echo")
        }

        installSignalGuard(restoring: original)
        func restoreTerminal() {
            var restored = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            removeSignalGuard()
        }

        // Echo stays off for the whole retry loop — only `return` and the
        // EOF `exit` below leave this function, and both restore first.
        while true {
            print(prompt, terminator: " ")
            guard let raw = readLine() else {
                restoreTerminal()
                print("\nCancelled.")
                exit(0)
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                restoreTerminal()
                print()
                return trimmed
            }
            print("\nA value is required.")
        }
    }

    /// y/N confirmation; defaults to no.
    static func confirm(prompt: String) -> Bool {
        print("\(prompt) [y/N]", terminator: " ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Prints why the client secret can't be safely prompted for and exits
    /// with a failure status. Never falls through to a plain-text prompt.
    private static func failClosed(reason: String) -> Never {
        FileHandle.standardError.write(Data("""
            error: cannot safely read the client secret (\(reason)); refusing to prompt in \
            the clear. Re-run `hudson auth` from an interactive terminal.

            """.utf8))
        exit(1)
    }

    // MARK: - Ctrl-C during the echo-off window

    /// The termios state to restore if SIGINT/SIGTERM arrives while echo is
    /// off. Set only for the lifetime of the echo-off prompt; read only from
    /// the signal handlers below, which is why it's safe to leave outside
    /// Swift's normal concurrency isolation.
    nonisolated(unsafe) private static var pendingRestore: termios?

    private static func installSignalGuard(restoring state: termios) {
        pendingRestore = state
        signal(SIGINT) { _ in
            if var state = ConsoleInput.pendingRestore {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
            }
            _exit(130)  // 128 + SIGINT, the conventional shell exit code
        }
        signal(SIGTERM) { _ in
            if var state = ConsoleInput.pendingRestore {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &state)
            }
            _exit(143)  // 128 + SIGTERM
        }
    }

    private static func removeSignalGuard() {
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        pendingRestore = nil
    }
}
