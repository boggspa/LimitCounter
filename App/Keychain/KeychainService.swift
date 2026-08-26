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

    /// Persists a credential and reports whether Keychain accepted the write.
    /// Callers that rotate browser sessions can use the result to avoid
    /// treating an in-memory token as durable when the OS rejected it.
    @discardableResult
    public func save(_ credential: ProviderCredential, for providerID: ProviderID) -> Bool {
        do {
            let data = try encoder.encode(credential)
            return write(data: data, account: providerID.rawValue)
        } catch {
            print("[KeychainService] Failed to encode credential for \(providerID.rawValue): \(error.localizedDescription)")
            return false
        }
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

    private func write(data: Data, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                logWriteFailure(operation: "add", account: account, status: addStatus)
                return false
            }
            return true
        }

        logWriteFailure(operation: "update", account: account, status: updateStatus)
        return false
    }

    private func logWriteFailure(operation: String, account: String, status: OSStatus) {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        print("[KeychainService] Keychain \(operation) failed for \(account): OSStatus \(status) (\(detail))")
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
