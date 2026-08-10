import Foundation

/// Terminal input helpers for the auth wizard.
enum ConsoleInput {
    /// Prompts and reads one trimmed line; empty input re-prompts.
    static func line(prompt: String) -> String {
        while true {
            print(prompt, terminator: " ")
            if let raw = readLine(), !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                return raw.trimmingCharacters(in: .whitespaces)
            }
            print("A value is required.")
        }
    }

    /// Reads a line with terminal echo off (for the client secret), so the
    /// value never appears on screen or in terminal scrollback.
    static func secret(prompt: String) -> String {
        print(prompt, terminator: " ")
        var terminalState = termios()
        tcgetattr(STDIN_FILENO, &terminalState)
        let originalState = terminalState
        terminalState.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &terminalState)
        defer {
            var restored = originalState
            tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            print()
        }
        return readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// y/N confirmation; defaults to no.
    static func confirm(prompt: String) -> Bool {
        print("\(prompt) [y/N]", terminator: " ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}
