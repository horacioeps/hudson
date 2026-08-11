import Foundation
import GmailKit
import Store
import Testing

@testable import HudsonUI

/// Enabling AI from Settings stores the key + opts every feature in with the
/// right models — the same rows the Summarize chip's `AIBootstrap` reads.
/// Uses an injected in-memory key store so nothing touches the real Keychain.
@MainActor
@Test func settingsEnableStoresKeyAndOptsInAllFeatures() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "c", consentedAt: Date())
    let keyStore = InMemoryLLMKeyStore()
    let settings = SettingsModel(database: db, account: "a@b.com", keyStore: keyStore)

    settings.provider = .anthropic
    settings.apiKey = "sk-ant-test"
    await settings.save()

    #expect(settings.isEnabled)
    #expect(try keyStore.key(provider: "anthropic") == "sk-ant-test")
    let summarize = try await db.aiConfig(feature: "summarize", account: "a@b.com")
    #expect(summarize?.optIn == true)
    #expect(summarize?.model == "claude-haiku-4-5")
    let draft = try await db.aiConfig(feature: "draft", account: "a@b.com")
    #expect(draft?.model == "claude-sonnet-5")

    await settings.disable()
    #expect(settings.isEnabled == false)
    #expect(try await db.aiConfig(feature: "summarize", account: "a@b.com")?.optIn == false)
}

/// A local (OpenAI-compatible) provider encodes the base URL the way
/// `AIBootstrap` decodes it, and works with an empty key.
@MainActor
@Test func settingsLocalProviderEncodesBaseURL() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@b.com", clientID: "c", consentedAt: Date())
    let settings = SettingsModel(database: db, account: "a@b.com", keyStore: InMemoryLLMKeyStore())

    settings.provider = .openAICompat
    settings.baseURL = "http://localhost:11434/v1"
    settings.model = "llama3.1"
    settings.apiKey = ""
    await settings.save()

    let cfg = try await db.aiConfig(feature: "summarize", account: "a@b.com")
    #expect(cfg?.optIn == true)
    #expect(cfg?.model == "llama3.1")
    #expect(cfg?.baseURL == "openai-compat|http://localhost:11434/v1")
}
