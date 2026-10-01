import os
import Foundation
import Security

/// Generic-password Keychain storage. Uses the login keychain, which works for
/// sandboxed apps without a provisioning profile.
nonisolated struct KeychainSecretStore: SecretStore {
    static let defaultService = (Bundle.main.bundleIdentifier ?? "com.weinnotes.MRCommandCenter") + ".tokens"

    let service: String

    init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    func secret(for account: String) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.invalidEncoding
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            Log.keychain.error("Keychain read failed with status \(status, privacy: .public)")
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    func setSecret(_ value: String, for account: String) throws {
        guard !value.isEmpty else { throw SecretStoreError.emptyValue }
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(
            baseQuery(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(for: account)
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "MR Command Center (\(account))"
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                Log.keychain.error("Keychain add failed with status \(addStatus, privacy: .public)")
                throw SecretStoreError.unexpectedStatus(addStatus)
            }
        default:
            Log.keychain.error("Keychain update failed with status \(updateStatus, privacy: .public)")
            throw SecretStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.keychain.error("Keychain delete failed with status \(status, privacy: .public)")
            throw SecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
