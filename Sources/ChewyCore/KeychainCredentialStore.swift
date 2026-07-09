import Foundation
import Security

public protocol CredentialStore {
    func saveSecret(_ secret: String, account: String) throws
    func readSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
    /// All (account → secret) items for this store's service, in one call. Used to
    /// migrate legacy per-account items into the consolidated vault entry.
    func readAllSecrets() throws -> [String: String]
}

public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "app.chewy.credentials"

    private let service: String

    public init(service: String = Self.defaultService) {
        self.service = service
    }

    public func saveSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw ChewyError.keychainFailure(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw ChewyError.keychainFailure(status)
        }
    }

    public func readSecret(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw ChewyError.keychainFailure(status)
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func readAllSecrets() throws -> [String: String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecReturnData as String: kCFBooleanTrue as Any
        ]
        query[kSecReturnRef as String] = nil

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else {
            throw ChewyError.keychainFailure(status)
        }
        guard let items = result as? [[String: Any]] else { return [:] }

        var out: [String: String] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            out[account] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    public func deleteSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChewyError.keychainFailure(status)
        }
    }

    /// Delete an arbitrary generic-password item by (service, account). Used to
    /// remove the transient, suffixed Claude staging credential after capture so
    /// live tokens do not linger outside the vault. A missing item is not an error.
    public static func deleteGenericPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChewyError.keychainFailure(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
