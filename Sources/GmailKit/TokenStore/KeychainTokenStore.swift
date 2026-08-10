import Foundation
import Security

/// Keychain-backed `TokenStore` using generic-password items in the login
/// keychain (the data-protection keychain needs entitlements a bare CLI can't
/// hold — spec §6.3). Items are ACL-bound to the CLI's signing identity;
/// `Scripts/sign-cli.sh` keeps that identity stable across rebuilds.
public struct KeychainTokenStore: TokenStore {
    /// Keychain `kSecAttrService` for every Hudson item.
    public static let service = "com.hudson.gmail"

    /// Initializes a token store backed by the macOS keychain.
    public init() {}

    public func saveTokens(_ tokens: TokenSet, account: String) throws {
        try write(try JSONEncoder().encode(tokens), key: "\(account)#tokens")
    }

    public func tokens(account: String) throws -> TokenSet? {
        try read(key: "\(account)#tokens").map { try JSONDecoder().decode(TokenSet.self, from: $0) }
    }

    public func saveClientSecret(_ secret: String, account: String) throws {
        try write(Data(secret.utf8), key: "\(account)#client-secret")
    }

    public func clientSecret(account: String) throws -> String? {
        try read(key: "\(account)#client-secret").map { String(decoding: $0, as: UTF8.self) }
    }

    public func deleteAll(account: String) throws {
        for key in ["\(account)#tokens", "\(account)#client-secret"] {
            let query = baseQuery(key: key)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
        }
    }

    // MARK: - Keychain plumbing

    private func baseQuery(key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: key,
        ]
    }

    private func write(_ data: Data, key: String) throws {
        var query = baseQuery(key: key)
        let update = [kSecValueData: data] as [CFString: Any]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keychainError(status) }
    }

    private func read(key: String) throws -> Data? {
        var query = baseQuery(key: key)
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
