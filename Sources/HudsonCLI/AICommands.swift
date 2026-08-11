import AIKit
import ArgumentParser
import Foundation
import GmailKit
import Store

/// The CLI verbs over AIKit (spec §8; architecture "M7 — AIKit"): `summarize`,
/// `draft`, `ask`, and `ai config`. Each `run()` is the explicit-action
/// boundary the whole privacy invariant hangs off of — it is the ONLY place
/// that mints an `Invocation` (`Invocation.userInvoked(...)`), and doing so
/// is what makes egress possible at all for that one call. Nothing in this
/// file, or anywhere else outside `EgressGuard`, calls `provider.stream`
/// directly.
///
/// Every command factors its post-wiring logic into a `static func execute`
/// that takes an already-built `AIRuntime` (or, for `ai config`, an already-
/// built `LocalRuntime` + `LLMKeyStore`) and a `print` sink instead of
/// touching stdout/Keychain/network itself — that is what lets
/// `AICommandsTests.swift` dry-run every command against a `ScriptedCLIProvider`
/// and an in-memory database with zero network or Keychain access, per the
/// plan's "TDD where feasible (arg parsing; a dry-run against a scripted
/// provider + temp DB)". `run()` itself is the thin, untested production
/// wiring layer (mirrors every other CLI command in this file's siblings —
/// e.g. `AuthCommand`, `TriageRunner`).

// MARK: - Provider selection

/// Which LLM backend `hudson ai config --provider` selects. `ArgumentParser`
/// needs `ExpressibleByArgument` declared explicitly for a type outside its
/// own module (see `ExpressibleByArgument.swift`: the free `init?(argument:)`
/// is only synthesized for types that already conform, it doesn't grant the
/// conformance itself) — declared directly here since this type is ours.
enum AIProviderKind: String, CaseIterable, Sendable, ExpressibleByArgument {
    case anthropic
    case openaiCompat = "openai-compat"
}

/// `AIFeature` (AIKit) has no `ExpressibleByArgument` conformance of its own
/// — AIKit has no reason to depend on ArgumentParser. Adding the conformance
/// here (not in AIKit) keeps that dependency direction intact while letting
/// `--feature` parse straight into the real type every AIKit API expects,
/// with no separate CLI-only mirror enum to keep in sync.
extension AIFeature: ExpressibleByArgument {}

/// Persisted CLI-side pairing of (provider kind, optional base-URL override).
///
/// `ai_config` has exactly the columns Task 1-7 already locked —
/// `model`/`base_url`/`opt_in` — and no new migration is allowed (plan
/// Global Constraints: "NO new migrations in M7"). No AIKit feature module
/// ever reads `base_url` (only `model`/`opt_in` feed `Summarize`/`Draft`/
/// `AskInbox`/`VoiceProfile` — see `AIStore.swift`'s `aiConfig` callers), so
/// it is free for the CLI to repurpose as ITS OWN opaque encoding of
/// "which provider, and what URL override" — the one piece of information
/// `ai config --provider` needs to persist that the schema has no column
/// for. The common case (no override) stores as a plain, readable
/// `"anthropic"`/`"openai-compat"`; a override appends `|<url>`.
struct AIProviderConfig: Equatable {
    let kind: AIProviderKind
    let baseURLOverride: URL?

    private static let separator: Character = "|"

    func encode() -> String {
        guard let baseURLOverride else { return kind.rawValue }
        return "\(kind.rawValue)\(Self.separator)\(baseURLOverride.absoluteString)"
    }

    /// Decodes a stored `base_url` column back into a provider selection.
    /// `nil` (feature never configured) or anything that fails to parse (a
    /// hand-edited or pre-encoding-scheme row) falls back to `.anthropic`
    /// with no override — a safe, inert default: `EgressGuard`'s opt-in
    /// gate, not this decode, is what actually blocks a never-configured
    /// feature from egressing, so an inert default here can never itself
    /// cause an unwanted network call.
    static func decode(_ raw: String?) -> AIProviderConfig {
        guard let raw, !raw.isEmpty else { return AIProviderConfig(kind: .anthropic, baseURLOverride: nil) }
        let parts = raw.split(separator: Self.separator, maxSplits: 1)
        guard let first = parts.first, let kind = AIProviderKind(rawValue: String(first)) else {
            return AIProviderConfig(kind: .anthropic, baseURLOverride: nil)
        }
        let override = parts.count > 1 ? URL(string: String(parts[1])) : nil
        return AIProviderConfig(kind: kind, baseURLOverride: override)
    }

    /// Builds the live provider this configuration names. Construction is
    /// pure (no I/O — see `AnthropicProvider`/`OpenAICompatProvider`'s own
    /// doc comments), so calling this for a not-yet-opted-in feature (see
    /// `AIRuntime.bootstrap`) is always safe: the resulting provider simply
    /// never gets called.
    func buildProvider(http: any LLMHTTP, apiKey: String) -> any LLMProvider {
        switch kind {
        case .anthropic:
            guard let baseURLOverride else { return AnthropicProvider(http: http, apiKey: apiKey) }
            return AnthropicProvider(http: http, apiKey: apiKey, baseURL: baseURLOverride)
        case .openaiCompat:
            guard let baseURLOverride else { return OpenAICompatProvider(http: http, apiKey: apiKey) }
            return OpenAICompatProvider(http: http, apiKey: apiKey, baseURL: baseURLOverride)
        }
    }
}

// MARK: - Object graph wiring

/// Wires the CLI's AIKit object graph for one invocation: the local account
/// (`LocalRuntime`, no Keychain/network — same seam every other CLI command
/// uses) plus an `EgressGuard` wrapping one `LLMProvider`.
///
/// A single provider/`EgressGuard` is built per top-level command invocation
/// even though `draft` internally cascades into a SECOND, separately-gated
/// `.voiceProfile` invocation (see `Draft.draft`'s doc comment) — the model
/// sent in each request still comes from THAT feature's own `ai_config` row
/// (`Summarize`/`Draft`/`VoiceProfile`/`AskInbox` each resolve their own
/// model independently), only the underlying HTTP transport/API key/base URL
/// is shared for the whole invocation tree. This assumes one LLM provider
/// account serves every feature, which is the realistic v1 setup (per-
/// feature MODEL choice, not per-feature PROVIDER account, is the axis
/// `ai_config` was designed to vary — architecture "M7 — AIKit": "Models are
/// config-driven via ai_config, never hardcoded"). Supporting fully
/// independent provider accounts per feature is future work, not required by
/// this task.
struct AIRuntime {
    let local: LocalRuntime
    let egressGuard: EgressGuard

    /// Production wiring: reads `feature`'s `ai_config` row, resolves the
    /// provider/base-URL it encodes (see `AIProviderConfig`), and the stored
    /// API key from the real Keychain (`KeychainLLMKeyStore`) — the ONLY
    /// place `AICommands.swift` builds a live `AnthropicProvider`/
    /// `OpenAICompatProvider` over the real streaming HTTP seam
    /// (`URLSessionLLMHTTP`). A feature with no `ai_config` row yet (or
    /// `opt_in = false`) still gets a fully-built `EgressGuard` here — it
    /// just refuses ever to call it (`AIError.notOptedIn`), since
    /// `EgressGuard.run` checks opt-in before any provider call.
    static func bootstrap(
        feature: AIFeature, keyStore: any LLMKeyStore = KeychainLLMKeyStore()
    ) async throws -> AIRuntime {
        let local = try await LocalRuntime.local()
        let config = try await local.database.aiConfig(
            feature: feature.rawValue, account: local.account.email)
        let providerConfig = AIProviderConfig.decode(config?.baseURL)
        // Local runtimes (Ollama/LM Studio) need no key (Task 4: "tolerate
        // an empty key") — an absent Keychain entry degrades to "", never a
        // thrown error, so a keyless local provider works with zero setup
        // beyond `ai config --opt-in`.
        let apiKey = try keyStore.key(provider: providerConfig.kind.rawValue) ?? ""
        let provider = providerConfig.buildProvider(http: URLSessionLLMHTTP(), apiKey: apiKey)
        return dryRun(local: local, provider: provider)
    }

    /// Test-only wiring (also used by `bootstrap` above once it has built a
    /// real provider): skips Keychain/network entirely, pairing an already-
    /// built `LocalRuntime` with an injected `LLMProvider` (a
    /// `ScriptedCLIProvider` in tests) straight into an `EgressGuard`.
    static func dryRun(local: LocalRuntime, provider: any LLMProvider) -> AIRuntime {
        AIRuntime(
            local: local,
            egressGuard: EgressGuard(
                provider: provider, database: local.database, account: local.account.email))
    }
}

// MARK: - AIError → clean stderr reporting (mirrors GmailErrorReporting.swift)

extension AIError {
    /// A plain, human-readable rendering for terminal display — same
    /// rationale as `GmailError.cliMessage`: `AIError` isn't
    /// `LocalizedError`, so letting it reach ArgumentParser's default
    /// handler debug-prints an unreadable `Error: notOptedIn(...)`.
    var cliMessage: String {
        switch self {
        case .notOptedIn(let feature):
            return """
                \(feature.rawValue) isn't opted in yet. Run:
                  hudson ai config --feature \(feature.rawValue) --provider anthropic \
                --model <model> --opt-in
                """
        case .transport(let message):
            return "Network error talking to the AI provider: \(message)"
        case .httpStatus(let code):
            return "The AI provider rejected the request (HTTP \(code))."
        case .emptyThread(let id):
            return "No messages found for thread \(Sanitizer.terminalSafe(id, singleLine: true))."
        }
    }
}

/// Prints an `AIError`'s message cleanly to stderr and returns
/// `ExitCode.failure` — `throw reportAndFail(error)`, exactly the
/// `GmailError` pattern every other command already uses.
func reportAndFail(_ error: AIError) -> Error {
    FileHandle.standardError.write(Data((error.cliMessage + "\n").utf8))
    return ExitCode.failure
}

// MARK: - Terminal-safe streaming sanitizer

/// Coalesces streamed LLM text before sanitizing it for the terminal.
///
/// Per-delta sanitization is unsafe (architecture doc, "Corrections that
/// must not be reintroduced": *"LLM output is untrusted → sanitize through
/// Sanitizer.terminalSafe on a coalesced buffer that carries a trailing
/// partial escape into the next chunk (per-delta sanitization lets an
/// attacker split one CSI/OSC across deltas)"*) — a provider (or, upstream
/// of it, a retrieved email body an attacker controls, per AskInbox's
/// prompt-injection caveat) can split one escape sequence across two SSE
/// deltas at any byte boundary. This holds back a trailing NOT-YET-COMPLETE
/// escape sequence across `feed` calls, so a split sequence is always
/// sanitized as one contiguous unit once its terminator (or the stream's
/// end) actually arrives, instead of leaking a still-forming fragment.
struct TerminalStreamSanitizer {
    private var pending = ""

    /// How long a not-yet-terminated tail is allowed to grow before this
    /// gives up waiting and flushes it anyway. Bounds worst-case buffering
    /// to a small constant so one stray ESC that never resolves into a real
    /// CSI/OSC sequence can't stall streaming output for the rest of a long
    /// response — real ANSI sequences (`\x1B[38;5;196m`, hyperlink OSCs) are
    /// far shorter than this in practice.
    private static let maxHeldTailLength = 128

    /// Feeds one more raw chunk of provider text; returns the sanitized text
    /// that is safe to print now (`""` if everything fed so far is being
    /// held back as a possibly-incomplete trailing escape).
    mutating func feed(_ chunk: String) -> String {
        pending += chunk
        let (safe, held) = Self.split(pending)
        guard held.count <= Self.maxHeldTailLength else {
            pending = ""
            return Sanitizer.terminalSafe(safe + held)
        }
        pending = held
        return Sanitizer.terminalSafe(safe)
    }

    /// Flushes whatever remains at end of stream. An incomplete trailing
    /// escape is still safe to sanitize as-is: `Sanitizer.terminalSafe`'s
    /// control-character filter strips a lone/incomplete ESC byte on its
    /// own even when it isn't part of a fully-recognized CSI/OSC form.
    mutating func finish() -> String {
        defer { pending = "" }
        return Sanitizer.terminalSafe(pending)
    }

    /// Splits `text` into a safe-to-flush prefix and a held-back suffix
    /// starting at the LAST escape (`ESC`, `\x1B`) introducer that is not
    /// yet a complete, terminated CSI/OSC sequence. Returns the whole string
    /// as `safe` with an empty `held` when there is no such trailing tail.
    private static func split(_ text: String) -> (safe: String, held: String) {
        guard let lastEscape = text.lastIndex(of: "\u{1B}") else { return (text, "") }
        let tail = String(text[lastEscape...])
        if isCompleteEscape(tail) { return (text, "") }
        return (String(text[text.startIndex..<lastEscape]), tail)
    }

    /// Whether `tail` (starting at an `ESC`) is ALREADY a complete,
    /// terminated CSI or OSC sequence — the same two terminated forms
    /// `Sanitizer.terminalSafe` itself recognizes (see its `pattern`s),
    /// anchored to match the ENTIRE tail so a still-growing prefix of a
    /// longer sequence (e.g. `"\x1B[31"`, waiting on its final byte) is
    /// correctly reported as NOT complete yet.
    private static func isCompleteEscape(_ tail: String) -> Bool {
        for pattern in [
            #"^(?:\x1B\[|\x{9B})[0-?]*[ -/]*[@-~]$"#,  // CSI … final byte
            #"^\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)$"#,  // OSC … BEL/ST
        ] {
            if tail.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }
}

// MARK: - hudson summarize

struct SummarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Summarize an email thread (cached; AI, explicit invocation only)."
    )

    @Argument(help: "The thread id (from `hudson list`/`hudson show`).")
    var threadID: String

    func run() async throws {
        do {
            let runtime = try await AIRuntime.bootstrap(feature: .summarize)
            try await Self.execute(threadID: threadID, runtime: runtime) {
                Swift.print($0, terminator: "")
            }
            print()
        } catch let error as GmailError {
            throw reportAndFail(error)
        } catch let error as AIError {
            throw reportAndFail(error)
        }
    }

    /// The `Invocation.userInvoked(.summarize)` call below IS the explicit-
    /// action boundary (this method only ever runs from `run()`, a real CLI
    /// invocation, or a test standing in for one) — see this file's header
    /// comment. Streamed text is sanitized through a coalescing
    /// `TerminalStreamSanitizer` before reaching `print`, never the raw
    /// provider deltas.
    static func execute(
        threadID: String, runtime: AIRuntime, print output: (String) -> Void
    ) async throws {
        let summarize = Summarize(
            guard: runtime.egressGuard, database: runtime.local.database,
            account: runtime.local.account.email)
        let stream = try await summarize.summarize(
            threadID: threadID, invocation: .userInvoked(.summarize))
        var sanitizer = TerminalStreamSanitizer()
        for try await chunk in stream {
            output(sanitizer.feed(chunk))
        }
        output(sanitizer.finish())
    }
}

// MARK: - hudson draft

struct DraftCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "draft",
        abstract: "Draft an email in your own voice (AI, explicit invocation only)."
    )

    @Option(name: .customLong("reply"), help: "Thread id to reply to (omit to draft a new email).")
    var replyTo: String?

    @Option(help: "What the draft should say.")
    var instruction: String

    func run() async throws {
        do {
            let runtime = try await AIRuntime.bootstrap(feature: .draft)
            try await Self.execute(
                replyTo: replyTo, instruction: instruction, runtime: runtime
            ) { Swift.print($0, terminator: "") }
            print()
        } catch let error as GmailError {
            throw reportAndFail(error)
        } catch let error as AIError {
            throw reportAndFail(error)
        }
    }

    /// Mints the top-level `.draft` invocation; `Draft.draft` internally
    /// mints its OWN separately-gated `.voiceProfile` invocation for the
    /// style-card fetch (see `Draft.swift`'s doc comment) — this command
    /// never touches `.voiceProfile` directly.
    static func execute(
        replyTo threadID: String?, instruction: String, runtime: AIRuntime,
        print output: (String) -> Void
    ) async throws {
        let voiceProfile = VoiceProfile(
            guard: runtime.egressGuard, database: runtime.local.database,
            account: runtime.local.account.email)
        let draft = Draft(
            guard: runtime.egressGuard, voiceProfile: voiceProfile, database: runtime.local.database,
            account: runtime.local.account.email)
        let stream = try await draft.draft(
            replyTo: threadID, instruction: instruction, invocation: .userInvoked(.draft))
        var sanitizer = TerminalStreamSanitizer()
        for try await chunk in stream {
            output(sanitizer.feed(chunk))
        }
        output(sanitizer.finish())
    }
}

// MARK: - hudson ask

struct AskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask a question over your inbox, with cited messages (AI, explicit invocation only)."
    )

    @Argument(help: "The question to ask.")
    var question: String

    func run() async throws {
        do {
            let runtime = try await AIRuntime.bootstrap(feature: .ask)
            try await Self.execute(question: question, runtime: runtime) {
                Swift.print($0, terminator: "")
            }
        } catch let error as GmailError {
            throw reportAndFail(error)
        } catch let error as AIError {
            throw reportAndFail(error)
        }
    }

    /// Streams the answer live, then appends the citations + hydration-
    /// coverage `AskInbox` always surfaces (spec §8: "Quality depends on
    /// body-hydration progress ..., which the CLI surfaces alongside
    /// answers") — printed once after the answer, since both arrive as
    /// terminal events on the same stream (`AskInbox.ask`'s doc comment).
    static func execute(
        question: String, runtime: AIRuntime, print output: (String) -> Void
    ) async throws {
        let askInbox = AskInbox(
            guard: runtime.egressGuard, database: runtime.local.database,
            account: runtime.local.account.email)
        let stream = try await askInbox.ask(question, invocation: .userInvoked(.ask))
        var sanitizer = TerminalStreamSanitizer()
        var citations: [String] = []
        var coverage = 1.0
        for try await event in stream {
            switch event {
            case .textDelta(let text):
                output(sanitizer.feed(text))
            case .citations(let ids):
                citations = ids
            case .coverage(let hydratedFraction):
                coverage = hydratedFraction
            }
        }
        output(sanitizer.finish())
        output("\n\n")
        if citations.isEmpty {
            output("Cited: (none)\n")
        } else {
            let safe = citations.map { Sanitizer.terminalSafe($0, singleLine: true) }
                .joined(separator: ", ")
            output("Cited: \(safe)\n")
        }
        output(String(format: "Coverage: %.0f%% of retrieved messages had a hydrated body.\n", coverage * 100))
    }
}

// MARK: - hudson ai config

struct AICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Configure Hudson's AI features.",
        subcommands: [AIConfigCommand.self]
    )
}

/// The ONLY command that turns a feature's opt-in on (spec §8; plan Task 8:
/// "`ai config` is the ONLY way opt-in is turned on"). `setAIConfig` always
/// overwrites `model`/`base_url`/`opt_in` together (`AIStore.swift`'s upsert
/// has no partial-update form) — so re-running this command WITHOUT
/// `--opt-in` resets opt-in to false even if it was previously on. That is
/// deliberate, not a bug: it keeps "a feature is opted in" an explicit,
/// freshly-stated fact of the most recent `ai config` call, matching this
/// codebase's "no ambient consent" posture, rather than a state that could
/// silently survive an unrelated model change.
struct AIConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Set one AI feature's model, provider, and opt-in state."
    )

    @Option(help: "Which AI feature to configure: summarize, draft, ask, or voiceProfile.")
    var feature: AIFeature

    @Option(help: "Which LLM backend to use.")
    var provider: AIProviderKind

    @Option(help: "Model name, e.g. claude-haiku-4-5 or claude-sonnet-5.")
    var model: String

    @Option(
        name: .customLong("base-url"),
        help: """
            Custom base URL (openai-compat only) — e.g. http://localhost:11434/v1 for Ollama, \
            http://localhost:1234/v1 for LM Studio, or an OpenRouter URL. Ignored for anthropic.
            """)
    var baseURL: String?

    @Option(
        name: .customLong("api-key"),
        help: """
            API key to store in the Keychain for this provider. Omit to leave any \
            already-stored key untouched — fine for a keyless local provider.
            """)
    var apiKey: String?

    @Flag(
        name: .customLong("opt-in"),
        help: """
            Allow this feature to send content to the configured provider. This is the ONLY \
            way opt-in is turned on — see this command's doc comment for why omitting it \
            resets opt-in to off.
            """)
    var optIn = false

    func run() async throws {
        do {
            let local = try await LocalRuntime.local()
            try await Self.execute(
                feature: feature, provider: provider, model: model, baseURL: baseURL,
                apiKey: apiKey, optIn: optIn, local: local, keyStore: KeychainLLMKeyStore())
            print(
                "Configured \(feature.rawValue): provider=\(provider.rawValue) model=\(model) opt_in=\(optIn)"
            )
        } catch let error as GmailError {
            throw reportAndFail(error)
        }
    }

    static func execute(
        feature: AIFeature, provider: AIProviderKind, model: String, baseURL: String?,
        apiKey: String?, optIn: Bool, local: LocalRuntime, keyStore: any LLMKeyStore
    ) async throws {
        // Never store an empty string as "the key" — that would overwrite a
        // real, previously-stored key with nothing on a config-only rerun
        // that happens to pass `--api-key ""`.
        if let apiKey, !apiKey.isEmpty {
            try keyStore.saveKey(apiKey, provider: provider.rawValue)
        }
        let override = baseURL.flatMap { URL(string: $0) }
        let encodedProvider = AIProviderConfig(kind: provider, baseURLOverride: override).encode()
        try await local.database.setAIConfig(
            feature: feature.rawValue, model: model, baseURL: encodedProvider, optIn: optIn,
            account: local.account.email)
    }
}
