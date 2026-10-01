import Foundation
import Security

/// Stores secrets (API tokens). The only place tokens are persisted.
nonisolated protocol SecretStore: Sendable {
    func secret(for account: String) throws -> String?
    func setSecret(_ value: String, for account: String) throws
    func removeSecret(for account: String) throws
}

extension SecretStore {
    func hasSecret(for account: String) -> Bool {
        guard let value = try? secret(for: account) else { return false }
        return !value.isEmpty
    }
}

/// Keychain account names. `AccountSettings` stores these references, never the tokens.
nonisolated enum SecretAccount {
    static let gitLabToken = "gitlab-token"
    static let jiraToken = "jira-token"
}

nonisolated enum SecretStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)
    case invalidEncoding
    case emptyValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        case .invalidEncoding:
            return "The Keychain item could not be read as text."
        case .emptyValue:
            return "The token is empty."
        }
    }
}
