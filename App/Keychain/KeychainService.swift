import Foundation
import Security

/// Stores and retrieves ProviderCredential values securely in the Keychain.
/// Main app only — widget reads only from App Group UserDefaults (no secrets).
public final class KeychainService {

    public static let shared = KeychainService()
    private let serviceName = "com.chrisizatt.LLMUsageCounter"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    // MARK: - Public API

    public func credential(for providerID: ProviderID) -> ProviderCredential? {
        guard let data = read(account: providerID.rawValue) else { return nil }
        return try? decoder.decode(ProviderCredential.self, from: data)
    }

    public func save(_ credential: ProviderCredential, for providerID: ProviderID) {
        guard let data = try? encoder.encode(credential) else { return }
        write(data: data, account: providerID.rawValue)
    }

    public func delete(for providerID: ProviderID) {
        delete(account: providerID.rawValue)
    }

    public func hasCredential(for providerID: ProviderID) -> Bool {
        credential(for: providerID) != nil
    }

    // MARK: - Keychain Primitives

    private func read(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      serviceName,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func write(data: Data, account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    private func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
