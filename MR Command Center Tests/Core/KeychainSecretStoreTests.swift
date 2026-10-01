import Foundation
import Testing
@testable import MR_Command_Center

/// Exercises the real Keychain under a throwaway service name.
@Suite(.serialized)
struct KeychainSecretStoreTests {
    let store = KeychainSecretStore(service: "com.weinnotes.MRCommandCenter.tests.\(UUID().uuidString)")
    let account = "test-token"

    @Test func roundTrip() throws {
        defer { try? store.removeSecret(for: account) }
        #expect(try store.secret(for: account) == nil)

        try store.setSecret("glpat-abc123", for: account)
        #expect(try store.secret(for: account) == "glpat-abc123")
        #expect(store.hasSecret(for: account))
    }

    @Test func updateOverwritesExistingValue() throws {
        defer { try? store.removeSecret(for: account) }
        try store.setSecret("first", for: account)
        try store.setSecret("second", for: account)
        #expect(try store.secret(for: account) == "second")
    }

    @Test func removeDeletesAndIsIdempotent() throws {
        try store.setSecret("value", for: account)
        try store.removeSecret(for: account)
        #expect(try store.secret(for: account) == nil)
        try store.removeSecret(for: account)
    }

    @Test func accountsAreIndependent() throws {
        defer {
            try? store.removeSecret(for: "a")
            try? store.removeSecret(for: "b")
        }
        try store.setSecret("one", for: "a")
        try store.setSecret("two", for: "b")
        #expect(try store.secret(for: "a") == "one")
        #expect(try store.secret(for: "b") == "two")
    }

    @Test func unicodeSurvivesRoundTrip() throws {
        defer { try? store.removeSecret(for: account) }
        try store.setSecret("tökën-🔑", for: account)
        #expect(try store.secret(for: account) == "tökën-🔑")
    }

    @Test func emptyValueIsRejected() {
        #expect(throws: SecretStoreError.emptyValue) {
            try store.setSecret("", for: account)
        }
    }
}
