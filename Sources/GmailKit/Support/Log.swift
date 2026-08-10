import OSLog

/// Central loggers. Spec §9.1 hard rule: NEVER log Authorization headers,
/// tokens, auth codes, client secrets, or message content. Network logs carry
/// method, path template, and status code only. Dynamic values default to
/// `.private` unless explicitly safe.
public enum Log {
    public static let transport = Logger(subsystem: "com.hudson.core", category: "transport")
    public static let auth = Logger(subsystem: "com.hudson.core", category: "auth")
    /// SyncEngine's category — skipped-message and progress warnings. Same
    /// content rule applies: error kind/status only, never message id/content.
    public static let sync = Logger(subsystem: "com.hudson.core", category: "sync")
}
