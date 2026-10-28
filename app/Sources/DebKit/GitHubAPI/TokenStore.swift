import Foundation

/// Where the GitHub PAT lives. A protocol so the package (and Linux CI) does
/// not depend on the Keychain; the iOS app uses KeychainTokenStore.
public protocol GitHubTokenStore: Sendable {
    func save(_ token: String) throws
    func load() throws -> String?
    func clear() throws
}

public struct TokenStoreError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Simple thread-safe in-memory store: unit tests, SwiftUI previews, and the
/// Linux CI runner.
public final class InMemoryTokenStore: GitHubTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init() {}

    public func save(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.token = token
    }

    public func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }
}

#if canImport(Security)
import Security

/// Keychain-backed PAT storage for the iOS app. The token is stored with
/// ThisDeviceOnly accessibility: it never leaves the device and is sent only
/// as an Authorization header to api.github.com over HTTPS.
public struct KeychainTokenStore: GitHubTokenStore {
    private let service: String
    private let account: String

    public init(service: String = "com.dain.deb2ipa", account: String = "github-pat") {
        self.service = service
        self.account = account
    }

    public func save(_ token: String) throws {
        clear()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TokenStoreError(message: "Keychain save failed with status \(status)")
        }
    }

    public func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        switch status {
        case errSecSuccess:
            guard let data = data as? Data, let token = String(data: data, encoding: .utf8) else {
                throw TokenStoreError(message: "Keychain returned unreadable token data")
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError(message: "Keychain read failed with status \(status)")
        }
    }

    public func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError(message: "Keychain delete failed with status \(status)")
        }
    }
}
#endif
