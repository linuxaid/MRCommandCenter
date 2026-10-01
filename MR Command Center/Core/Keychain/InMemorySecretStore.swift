import Foundation
import Synchronization

/// Secret store for previews, mock mode, and tests.
nonisolated final class InMemorySecretStore: SecretStore {
    private let storage: Mutex<[String: String]>

    init(_ initial: [String: String] = [:]) {
        storage = Mutex(initial)
    }

    func secret(for account: String) throws -> String? {
        storage.withLock { $0[account] }
    }

    func setSecret(_ value: String, for account: String) throws {
        guard !value.isEmpty else { throw SecretStoreError.emptyValue }
        storage.withLock { $0[account] = value }
    }

    func removeSecret(for account: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: account) }
    }
}
