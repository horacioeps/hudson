import Foundation
import Testing
@testable import GmailKit

// MARK: - RED: round trip + per-provider isolation, mirrors TokenStoreTests

@Test func roundTripsKeyPerProvider() throws {
    let store = InMemoryLLMKeyStore()
    try store.saveKey("sk-anthropic-123", provider: "anthropic")
    try store.saveKey("sk-openai-456", provider: "openai")
    #expect(try store.key(provider: "anthropic") == "sk-anthropic-123")
    #expect(try store.key(provider: "openai") == "sk-openai-456")
}

@Test func unknownProviderReturnsNil() throws {
    #expect(try InMemoryLLMKeyStore().key(provider: "anthropic") == nil)
}

@Test func saveKeyOverwritesExistingValueForSameProvider() throws {
    let store = InMemoryLLMKeyStore()
    try store.saveKey("old-key", provider: "anthropic")
    try store.saveKey("new-key", provider: "anthropic")
    #expect(try store.key(provider: "anthropic") == "new-key")
}

@Test func deleteKeyRemovesOnlyThatProviderKey() throws {
    let store = InMemoryLLMKeyStore()
    try store.saveKey("a-key", provider: "anthropic")
    try store.saveKey("o-key", provider: "openai")
    try store.deleteKey(provider: "anthropic")
    #expect(try store.key(provider: "anthropic") == nil)
    #expect(try store.key(provider: "openai") == "o-key")
}

@Test func deleteKeyForUnknownProviderIsANoOp() throws {
    let store = InMemoryLLMKeyStore()
    try store.deleteKey(provider: "anthropic")   // must not throw
    #expect(try store.key(provider: "anthropic") == nil)
}
