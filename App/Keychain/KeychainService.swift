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

    /// The primary account's credential. Every provider-keyed call is the
    /// account-keyed one for that provider's primary account, so the keychain
    /// item name (`kSecAttrAccount`) a pre-account install wrote is unchanged.
    public func credential(for providerID: ProviderID) -> ProviderCredential? {
        credential(for: .primary(providerID))
    }

    public func credential(for account: ProviderAccountKey) -> ProviderCredential? {
        guard let data = read(account: account.rawValue) else { return nil }
        return try? decoder.decode(ProviderCredential.self, from: data)
    }

    /// Persists a credential and reports whether Keychain accepted the write.
    /// Callers that rotate browser sessions can use the result to avoid
    /// treating an in-memory token as durable when the OS rejected it.
    @discardableResult
    public func save(_ credential: ProviderCredential, for providerID: ProviderID) -> Bool {
        save(credential, for: .primary(providerID))
    }

    @discardableResult
    public func save(_ credential: ProviderCredential, for account: ProviderAccountKey) -> Bool {
        do {
            let data = try encoder.encode(credential)
            return write(data: data, account: account.rawValue)
        } catch {
            print("[KeychainService] Failed to encode credential for \(account.rawValue): \(error.localizedDescription)")
            return false
        }
    }

    /// Atomically merges credential metadata and persists the complete
    /// credential. Rotating browser sessions use this to avoid rebuilding a
    /// credential from a stale copy and clobbering unrelated fields.
    @discardableResult
    public func updateExtraFields(
        _ updates: [String: String],
        for providerID: ProviderID
    ) -> Bool {
        updateExtraFields(updates, for: .primary(providerID))
    }

    @discardableResult
    public func updateExtraFields(
        _ updates: [String: String],
        for account: ProviderAccountKey
    ) -> Bool {
        guard let credential = credential(for: account) else {
            print("[KeychainService] Cannot update \(account.rawValue): stored credential is unavailable")
            return false
        }

        var extraFields = credential.extraFields ?? [:]
        for (key, value) in updates {
            extraFields[key] = value
        }
        let updated = ProviderCredential(
            accessToken: credential.accessToken,
            accountIdentifier: credential.accountIdentifier,
            customEndpoint: credential.customEndpoint,
            extraFields: extraFields,
            bookmarkData: credential.bookmarkData
        )
        return save(updated, for: account)
    }

    public func delete(for providerID: ProviderID) {
        delete(for: .primary(providerID))
    }

    public func delete(for account: ProviderAccountKey) {
        delete(account: account.rawValue)
    }

    public func hasCredential(for providerID: ProviderID) -> Bool {
        hasCredential(for: .primary(providerID))
    }

    public func hasCredential(for account: ProviderAccountKey) -> Bool {
        credential(for: account) != nil
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
