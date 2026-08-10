import Foundation
import Security
import Synchronization

/// Persistence seam for LLM provider API keys — the storage half of M7's
/// summarize/draft/ask-inbox features (no provider or egress code lives
/// here; this is only where a user's own key gets kept). Production uses
/// `KeychainLLMKeyStore`; tests use `InMemoryLLMKeyStore` so CI never
/// touches a real keychain — the exact same seam `TokenStore` provides for
/// OAuth tokens (see `Sources/GmailKit/TokenStore/`), mirrored here for a
/// second class of secret with a different lifecycle (one key per
/// `provider`, e.g. "anthropic"/"openai", rather than per Gmail account).
public protocol LLMKeyStore: Sendable {
    func saveKey(_ key: String, provider: String) throws
    func key(provider: String) throws -> String?
    func deleteKey(provider: String) throws
}

/// Test/preview implementation of `LLMKeyStore`. Thread-safe, non-persistent.
public final class InMemoryLLMKeyStore: LLMKeyStore {
    private let keys = Mutex<[String: String]>([:])

    /// Initializes a thread-safe in-memory key store for testing.
    public init() {}

    public func saveKey(_ key: String, provider: String) throws {
        keys.withLock { $0[provider] = key }
    }

    public func key(provider: String) throws -> String? {
        keys.withLock { $0[provider] }
    }

    public func deleteKey(provider: String) throws {
        keys.withLock { $0[provider] = nil }
    }
}

/// Keychain-backed `LLMKeyStore` using generic-password items in the login
/// keychain — mirrors `KeychainTokenStore`'s SecItem code exactly (same
/// data-protection-keychain rationale: a bare CLI can't hold the
/// entitlements the data-protection keychain needs), under its own service
/// so LLM provider keys never collide with OAuth secrets in the keychain.
public struct KeychainLLMKeyStore: LLMKeyStore {
    /// Keychain `kSecAttrService` for every LLM provider key item.
    public static let service = "com.hudson.llm"

    /// Initializes a key store backed by the macOS keychain.
    public init() {}

    public func saveKey(_ key: String, provider: String) throws {
        try write(Data(key.utf8), provider: provider)
    }

    public func key(provider: String) throws -> String? {
        try read(provider: provider).map { String(decoding: $0, as: UTF8.self) }
    }

    public func deleteKey(provider: String) throws {
        let query = baseQuery(provider: provider)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    // MARK: - Keychain plumbing (mirrors KeychainTokenStore)

    private func baseQuery(provider: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: provider,
        ]
    }

    private func write(_ data: Data, provider: String) throws {
        var query = baseQuery(provider: provider)
        let update = [kSecValueData: data] as [CFString: Any]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    private func read(provider: String) throws -> Data? {
        var query = baseQuery(provider: provider)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data)
        case errSecItemNotFound: return nil
        default: throw keychainError(status)
        }
    }

    private func keychainError(_ status: OSStatus) -> GmailError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .auth("Keychain operation failed: \(message)")
    }
}
