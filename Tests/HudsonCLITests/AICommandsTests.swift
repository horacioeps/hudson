import ArgumentParser
import Foundation
import GmailKit
import Store
import Testing

@testable import AIKit
@testable import HudsonCLI

private let account = "user@example.com"

// MARK: - Test doubles (kept local to this file — per-file fixture
// convention established by Tests/AIKitTests/*, e.g. SummarizeTests.swift's
// `snap`/`collectText`: each test file's fixture shape stays obvious at its
// own call site rather than importing another target's test-only types).

/// A minimal `LLMProvider` double: replays one script per call (repeating
/// the last script once exhausted, mirroring `Tests/AIKitTests/ScriptedProvider.swift`),
/// and records every request so tests can assert what actually got sent.
/// Never touches the network — this is exactly what makes the CLI's
/// "dry run" tests possible without a real provider or Keychain.
private final class ScriptedCLIProvider: LLMProvider, @unchecked Sendable {
    private var scripts: [[LLMEvent]]
    private(set) var requests: [LLMRequest] = []

    init(script: [LLMEvent]) { self.scripts = [script] }
    init(scripts: [[LLMEvent]]) { self.scripts = scripts }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        requests.append(request)
        let script = scripts[min(requests.count - 1, scripts.count - 1)]
        return AsyncThrowingStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Builds an isolated in-memory `LocalRuntime` with one seeded account —
/// mirrors `Tests/HudsonCLITests/UndoInverseDeltaTests.swift`'s `makeTestRuntime`.
private func makeLocalRuntime() async throws -> (HudsonDatabase, LocalRuntime) {
    let database = try HudsonDatabase.inMemory()
    try await database.upsertAccount(email: account, clientID: "client", consentedAt: Date())
    let record = try #require(try await database.primaryAccount())
    return (database, LocalRuntime(database: database, account: record))
}

private func snap(
    _ id: String, thread: String = "t1", from: String = "alice@example.com",
    subject: String = "Hello", date: Int64 = 1, labels: [String] = ["INBOX"]
) -> MessageSnapshot {
    MessageSnapshot(
        id: id, threadID: thread, historyID: date, internalDate: date,
        fromLine: from, toLine: "bob@example.com", subject: subject, snippet: "sn",
        labelIDs: labels)
}

/// Collects everything a captured `print` closure received into one string.
private final class Capture: @unchecked Sendable {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}

// MARK: - Argument parsing

@Test func summarizeParsesThreadIDArgument() throws {
    let command = try SummarizeCommand.parse(["t-123"])
    #expect(command.threadID == "t-123")
}

@Test func draftParsesReplyAndInstruction() throws {
    let command = try DraftCommand.parse(["--reply", "t-1", "--instruction", "say hi"])
    #expect(command.replyTo == "t-1")
    #expect(command.instruction == "say hi")
}

@Test func draftWithoutReplyIsANewEmail() throws {
    let command = try DraftCommand.parse(["--instruction", "say hi"])
    #expect(command.replyTo == nil)
}

@Test func askParsesQuestionArgument() throws {
    let command = try AskCommand.parse(["What's the status of the invoice?"])
    #expect(command.question == "What's the status of the invoice?")
}

@Test func aiConfigParsesAllFlags() throws {
    let command = try AIConfigCommand.parse([
        "--feature", "summarize", "--provider", "anthropic",
        "--model", "claude-haiku-4-5", "--opt-in",
    ])
    #expect(command.feature == .summarize)
    #expect(command.provider == .anthropic)
    #expect(command.model == "claude-haiku-4-5")
    #expect(command.optIn == true)
    #expect(command.baseURL == nil)
}

@Test func aiConfigParsesOpenAICompatWithBaseURL() throws {
    let command = try AIConfigCommand.parse([
        "--feature", "draft", "--provider", "openai-compat",
        "--model", "llama3", "--base-url", "http://localhost:11434/v1",
    ])
    #expect(command.provider == .openaiCompat)
    #expect(command.baseURL == "http://localhost:11434/v1")
    #expect(command.optIn == false)  // omitted --opt-in => false
}

@Test func aiConfigRejectsUnknownProvider() {
    #expect(throws: (any Error).self) {
        _ = try AIConfigCommand.parse([
            "--feature", "summarize", "--provider", "bogus", "--model", "m",
        ])
    }
}

// MARK: - AIProviderConfig (base_url column encoding — see AICommands.swift)

@Test func providerConfigEncodesAndDecodesWithNoOverride() {
    let config = AIProviderConfig(kind: .openaiCompat, baseURLOverride: nil)
    let decoded = AIProviderConfig.decode(config.encode())
    #expect(decoded == config)
}

@Test func providerConfigEncodesAndDecodesWithOverride() {
    let url = URL(string: "http://localhost:1234/v1")!
    let config = AIProviderConfig(kind: .openaiCompat, baseURLOverride: url)
    let decoded = AIProviderConfig.decode(config.encode())
    #expect(decoded == config)
}

@Test func providerConfigDecodesNilAsAnthropicWithNoOverride() {
    #expect(AIProviderConfig.decode(nil) == AIProviderConfig(kind: .anthropic, baseURLOverride: nil))
}

@Test func providerConfigDecodesGarbageAsAnthropicWithNoOverride() {
    // A row from before this encoding existed, or manual corruption — never
    // crash, just fall back to the safe default (EgressGuard's opt-in gate,
    // not this decode, is what actually blocks a never-configured feature).
    #expect(
        AIProviderConfig.decode("garbage-not-a-known-provider")
            == AIProviderConfig(kind: .anthropic, baseURLOverride: nil))
}

// MARK: - TerminalStreamSanitizer (coalesced-buffer escape reassembly)

@Test func sanitizerPassesPlainTextThroughUnchanged() {
    var sanitizer = TerminalStreamSanitizer()
    var out = sanitizer.feed("Hello, ")
    out += sanitizer.feed("world!")
    out += sanitizer.finish()
    #expect(out == "Hello, world!")
}

@Test func sanitizerStripsAnEscapeSequenceContainedInOneChunk() {
    var sanitizer = TerminalStreamSanitizer()
    var out = sanitizer.feed("before \u{1B}[31mred\u{1B}[0m after")
    out += sanitizer.finish()
    #expect(out == "before red after")
    #expect(!out.contains("\u{1B}"))
}

/// The exact scenario the architecture doc's "Corrections" section warns
/// about: one CSI sequence split across two deltas at the ESC boundary.
/// Per-delta sanitization can't see the whole sequence in either half; this
/// must still fully strip it once both halves have arrived.
@Test func sanitizerReassemblesAnEscapeSequenceSplitAcrossChunks() {
    var sanitizer = TerminalStreamSanitizer()
    var out = sanitizer.feed("before \u{1B}[31")
    out += sanitizer.feed("mred\u{1B}[0m after")
    out += sanitizer.finish()
    #expect(out == "before red after")
    #expect(!out.contains("\u{1B}"))
}

@Test func sanitizerReassemblesASplitRightAtTheEscapeByte() {
    var sanitizer = TerminalStreamSanitizer()
    var out = sanitizer.feed("before \u{1B}")
    out += sanitizer.feed("[31mred\u{1B}[0m after")
    out += sanitizer.finish()
    #expect(out == "before red after")
    #expect(!out.contains("\u{1B}"))
}

@Test func sanitizerFlushesATrailingIncompleteEscapeOnFinish() {
    var sanitizer = TerminalStreamSanitizer()
    var out = sanitizer.feed("hello \u{1B}[31")
    out += sanitizer.finish()
    // No terminator ever arrives — finish() must still flush safely with no
    // raw control byte reaching the caller.
    #expect(!out.contains("\u{1B}"))
}

@Test func sanitizerDoesNotBufferForeverAfterAStrayEscape() {
    var sanitizer = TerminalStreamSanitizer()
    _ = sanitizer.feed("stray \u{1B}")
    // A long run of ordinary text after a stray ESC that never resolves
    // into a real CSI/OSC sequence must eventually flush (streaming must not
    // silently stall for the rest of a long response).
    var out = ""
    for _ in 0..<20 {
        out += sanitizer.feed(String(repeating: "x", count: 20))
    }
    out += sanitizer.finish()
    #expect(out.contains("xxxxxxxxxx"))
    #expect(!out.contains("\u{1B}"))
}

// MARK: - AIRuntime + command execute() dry runs (scripted provider, temp/in-memory DB)

@Test func summarizeExecuteStreamsAndSanitizesOutput() async throws {
    let (database, local) = try await makeLocalRuntime()
    _ = try await database.applySnapshot(snap("m1", date: 100), account: account)
    try await database.saveBody(
        messageID: "m1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Let's meet Tuesday."))
    try await database.setAIConfig(
        feature: AIFeature.summarize.rawValue, model: "claude-haiku-4-5", baseURL: nil, optIn: true,
        account: account)
    let provider = ScriptedCLIProvider(script: [.textDelta("They "), .textDelta("agreed."), .stopped])
    let runtime = AIRuntime.dryRun(local: local, provider: provider)
    let capture = Capture()

    try await SummarizeCommand.execute(threadID: "t1", runtime: runtime, print: capture.append)

    #expect(capture.text == "They agreed.")
    #expect(provider.requests.count == 1)
}

@Test func summarizeExecuteThrowsNotOptedInAndNeverCallsProvider() async throws {
    let (database, local) = try await makeLocalRuntime()
    _ = try await database.applySnapshot(snap("m1", date: 100), account: account)
    let provider = ScriptedCLIProvider(script: [.textDelta("nope"), .stopped])
    let runtime = AIRuntime.dryRun(local: local, provider: provider)
    let capture = Capture()

    await #expect(throws: AIError.notOptedIn(.summarize)) {
        try await SummarizeCommand.execute(threadID: "t1", runtime: runtime, print: capture.append)
    }
    #expect(provider.requests.isEmpty)
}

@Test func draftExecuteBuildsVoiceAndThreadContextAndStreams() async throws {
    let (database, local) = try await makeLocalRuntime()
    _ = try await database.applySnapshot(
        snap("sent1", thread: "sentThread", from: "me@example.com", labels: ["SENT"]), account: account)
    try await database.saveBody(
        messageID: "sent1", account: account,
        body: Sanitizer.sanitize(html: nil, plainText: "Hey! Talk soon. -Me"))
    _ = try await database.applySnapshot(snap("m1", thread: "t1", date: 50), account: account)
    try await database.saveBody(
        messageID: "m1", account: account, body: Sanitizer.sanitize(html: nil, plainText: "Can you send the file?"))
    try await database.setAIConfig(
        feature: AIFeature.draft.rawValue, model: "claude-sonnet-5", baseURL: nil, optIn: true,
        account: account)
    try await database.setAIConfig(
        feature: AIFeature.voiceProfile.rawValue, model: "claude-sonnet-5", baseURL: nil, optIn: true,
        account: account)
    // Two hops: voice-profile distillation, then the draft itself.
    let provider = ScriptedCLIProvider(scripts: [
        [.textDelta("Casual, signs off '-Me'."), .stopped],
        [.textDelta("Sure, "), .textDelta("attached!"), .stopped],
    ])
    let runtime = AIRuntime.dryRun(local: local, provider: provider)
    let capture = Capture()

    try await DraftCommand.execute(
        replyTo: "t1", instruction: "say yes", runtime: runtime, print: capture.append)

    #expect(capture.text == "Sure, attached!")
    #expect(provider.requests.count == 2)
    let draftPrompt = provider.requests.last?.messages.first?.text ?? ""
    #expect(draftPrompt.contains("Can you send the file?"))
    #expect(draftPrompt.contains("say yes"))
}

@Test func askExecuteStreamsAnswerThenPrintsCitationsAndCoverage() async throws {
    let (database, local) = try await makeLocalRuntime()
    _ = try await database.applySnapshot(snap("m1", subject: "Invoice", date: 100), account: account)
    try await database.saveBody(
        messageID: "m1", account: account, body: Sanitizer.sanitize(html: nil, plainText: "Invoice attached."))
    try await database.setAIConfig(
        feature: AIFeature.ask.rawValue, model: "claude-sonnet-5", baseURL: nil, optIn: true,
        account: account)
    let provider = ScriptedCLIProvider(script: [.textDelta("The invoice was sent."), .stopped])
    let runtime = AIRuntime.dryRun(local: local, provider: provider)
    let capture = Capture()

    try await AskCommand.execute(question: "invoice", runtime: runtime, print: capture.append)

    #expect(capture.text.contains("The invoice was sent."))
    #expect(capture.text.contains("m1"))
    #expect(capture.text.contains("100%"))
}

@Test func aiConfigExecuteWritesConfigAndStoresKey() async throws {
    let (database, local) = try await makeLocalRuntime()
    let keyStore = InMemoryLLMKeyStore()

    try await AIConfigCommand.execute(
        feature: .summarize, provider: .anthropic, model: "claude-haiku-4-5", baseURL: nil,
        apiKey: "sk-test-123", optIn: true, local: local, keyStore: keyStore)

    let config = try await database.aiConfig(feature: "summarize", account: account)
    #expect(config?.model == "claude-haiku-4-5")
    #expect(config?.optIn == true)
    #expect(try keyStore.key(provider: "anthropic") == "sk-test-123")
    // The persisted base_url column decodes back to the chosen provider —
    // see AIProviderConfig's doc comment for why this column carries that.
    #expect(AIProviderConfig.decode(config?.baseURL) == AIProviderConfig(kind: .anthropic, baseURLOverride: nil))
}

@Test func aiConfigExecuteOmittedAPIKeyLeavesExistingKeyUntouched() async throws {
    let (_, local) = try await makeLocalRuntime()
    let keyStore = InMemoryLLMKeyStore()
    try keyStore.saveKey("already-stored", provider: "anthropic")

    try await AIConfigCommand.execute(
        feature: .summarize, provider: .anthropic, model: "claude-haiku-4-5", baseURL: nil,
        apiKey: nil, optIn: true, local: local, keyStore: keyStore)

    #expect(try keyStore.key(provider: "anthropic") == "already-stored")
}

@Test func aiConfigExecuteStoresOpenAICompatBaseURLOverride() async throws {
    let (database, local) = try await makeLocalRuntime()
    let keyStore = InMemoryLLMKeyStore()

    try await AIConfigCommand.execute(
        feature: .draft, provider: .openaiCompat, model: "llama3",
        baseURL: "http://localhost:11434/v1", apiKey: nil, optIn: false, local: local, keyStore: keyStore)

    let config = try await database.aiConfig(feature: "draft", account: account)
    let decoded = AIProviderConfig.decode(config?.baseURL)
    #expect(decoded.kind == .openaiCompat)
    #expect(decoded.baseURLOverride == URL(string: "http://localhost:11434/v1"))
}
