import AIKit
import Foundation
import GmailKit
import Store
import Testing

@testable import HudsonUI

// MARK: - Consent: storing a key is not consenting to egress

/// The whole point of `save(optIn:)`. Pasting an API key and agreeing that your
/// email may be sent to that provider are two different decisions, and
/// onboarding must be able to take the first without the second — otherwise the
/// key field itself becomes an egress switch.
@MainActor
@Test func savingAKeyWithoutOptInStoresTheKeyAndLeavesEveryFeatureOff() async throws {
    let db = try HudsonDatabase.inMemory()
    let keyStore = InMemoryLLMKeyStore()
    let settings = SettingsModel(
        database: db, account: "a@example.com", keyStore: keyStore)
    settings.provider = .anthropic
    settings.apiKey = "sk-ant-test"

    await settings.save(optIn: false)

    #expect(try keyStore.key(provider: "anthropic") == "sk-ant-test")
    #expect(!settings.isEnabled)
    for feature in [AIFeature.summarize, .draft, .ask, .voiceProfile] {
        let config = try await db.aiConfig(feature: feature.rawValue, account: "a@example.com")
        #expect(config?.optIn == false)
    }
}

/// The Settings sheet's own meaning is unchanged: its button really does enable
/// AI.
@MainActor
@Test func savingWithOptInEnablesEveryFeature() async throws {
    let db = try HudsonDatabase.inMemory()
    let settings = SettingsModel(
        database: db, account: "a@example.com", keyStore: InMemoryLLMKeyStore())
    settings.provider = .anthropic
    settings.apiKey = "sk-ant-test"

    await settings.save()

    #expect(settings.isEnabled)
    let config = try await db.aiConfig(feature: "summarize", account: "a@example.com")
    #expect(config?.optIn == true)
}

/// Opting in with no key would leave every AI surface enabled-looking and
/// failing at the point of use — and, worse for a fail-closed design, would put
/// the account in a state where merely pasting a key later starts egressing
/// with no further consent. It refuses, and says why.
@MainActor
@Test func optingInWithoutAKeyIsRefusedAndReportedHonestly() async throws {
    let db = try HudsonDatabase.inMemory()
    let settings = SettingsModel(
        database: db, account: "a@example.com", keyStore: InMemoryLLMKeyStore())
    settings.provider = .anthropic
    settings.apiKey = ""

    await settings.save(optIn: true)

    #expect(!settings.isEnabled)
    #expect(settings.banner == "Add an API key to turn AI on.")
    let config = try await db.aiConfig(feature: "summarize", account: "a@example.com")
    #expect(config?.optIn == false)
}

/// A local OpenAI-compatible server (Ollama, LM Studio) is legitimately
/// keyless, so the key requirement must not apply to it.
@MainActor
@Test func aKeylessLocalProviderMayStillOptIn() async throws {
    let db = try HudsonDatabase.inMemory()
    let settings = SettingsModel(
        database: db, account: "a@example.com", keyStore: InMemoryLLMKeyStore())
    settings.provider = .openAICompat
    settings.baseURL = "http://localhost:11434/v1"
    settings.model = "llama3.1"
    settings.apiKey = ""

    await settings.save(optIn: true)

    #expect(settings.isEnabled)
}

// MARK: - Turning AI off must not rewrite which provider it would use

/// The privacy bug in the old `disable()`: it re-wrote every row with
/// `model: ""`, `baseURL: nil`, erasing the provider encoding — so a user
/// running a LOCAL model, whose entire point is that nothing leaves the
/// machine, silently came back as cloud Anthropic when they re-enabled.
@MainActor
@Test func disablingPreservesTheProviderSoALocalModelDoesNotBecomeCloud() async throws {
    let db = try HudsonDatabase.inMemory()
    let settings = SettingsModel(
        database: db, account: "a@example.com", keyStore: InMemoryLLMKeyStore())
    settings.provider = .openAICompat
    settings.baseURL = "http://localhost:11434/v1"
    settings.model = "llama3.1"
    await settings.save()

    await settings.disable()

    let config = try #require(
        try await db.aiConfig(feature: "summarize", account: "a@example.com"))
    #expect(config.optIn == false)
    #expect(config.baseURL == "openai-compat|http://localhost:11434/v1")
    #expect(config.model == "llama3.1")
}

// MARK: - Disconnect revokes consent

/// `ai_config` has no foreign key to `accounts`, so its rows outlive a
/// disconnect. Without an explicit revoke, reconnecting the same address would
/// silently restore an `opt_in = 1` granted in a previous session — and the
/// first Summarize tap would egress against consent the user has every reason
/// to believe they revoked.
@MainActor
@Test func disconnectingRevokesAIConsentSoAReconnectDoesNotResurrectIt() async throws {
    let db = try HudsonDatabase.inMemory()
    try await db.upsertAccount(email: "a@example.com", clientID: "id", consentedAt: .now)
    try await db.setAIConfig(
        feature: "summarize", model: "claude-haiku-4-5", baseURL: nil,
        optIn: true, account: "a@example.com")
    let account = try #require(try await db.primaryAccount())
    let model = AppModel(
        database: db, account: account, tokenStore: InMemoryTokenStore())

    await model.disconnectAccount()

    let config = try #require(
        try await db.aiConfig(feature: "summarize", account: "a@example.com"))
    #expect(config.optIn == false)
    #expect(model.account == nil)
}
