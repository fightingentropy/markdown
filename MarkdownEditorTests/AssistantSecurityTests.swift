import Foundation
import XCTest

@testable import Markdown

@MainActor
final class AssistantSecurityTests: XCTestCase {
    private static let legacyDefaultsKey = "assistant.apiKey"

    func testPlaintextAPIKeyMigratesToKeychainAndScrubsDefaults() {
        let defaults = makeDefaults()
        defaults.set("  migration-secret  ", forKey: Self.legacyDefaultsKey)
        let store = InMemoryAPIKeyStore()

        let settings = AssistantSettings(userDefaults: defaults, apiKeyStore: store)

        XCTAssertEqual(settings.apiKey, "migration-secret")
        XCTAssertEqual(store.value, "migration-secret")
        XCTAssertNil(defaults.object(forKey: Self.legacyDefaultsKey))
    }

    func testFailedMigrationRetainsLegacyValueForRetry() {
        let defaults = makeDefaults()
        defaults.set("migration-secret", forKey: Self.legacyDefaultsKey)
        let store = InMemoryAPIKeyStore()
        store.saveError = TestStoreError.unavailable

        let settings = AssistantSettings(userDefaults: defaults, apiKeyStore: store)

        XCTAssertEqual(settings.apiKey, "migration-secret")
        XCTAssertEqual(defaults.string(forKey: Self.legacyDefaultsKey), "migration-secret")
        XCTAssertNil(store.value)
    }

    func testExistingKeychainValueLoadsWithoutWritingDefaults() {
        let defaults = makeDefaults()
        let store = InMemoryAPIKeyStore(value: "keychain-secret")

        let settings = AssistantSettings(userDefaults: defaults, apiKeyStore: store)

        XCTAssertEqual(settings.apiKey, "keychain-secret")
        XCTAssertNil(defaults.object(forKey: Self.legacyDefaultsKey))
    }

    func testNewAPIKeyIsNormalizedAndStoredOnlyInKeychain() {
        let defaults = makeDefaults()
        let store = InMemoryAPIKeyStore()
        let settings = AssistantSettings(userDefaults: defaults, apiKeyStore: store)

        settings.apiKey = "  newly-entered-secret\n"

        XCTAssertEqual(settings.apiKey, "newly-entered-secret")
        XCTAssertEqual(store.value, "newly-entered-secret")
        XCTAssertNil(defaults.object(forKey: Self.legacyDefaultsKey))
        XCTAssertEqual(store.saveCallCount, 1, "Normalization must not recursively persist the key")
    }

    func testClearingAPIKeyDeletesKeychainItemAndAnyLegacyDefault() {
        let defaults = makeDefaults()
        defaults.set("stale-plaintext", forKey: Self.legacyDefaultsKey)
        let store = InMemoryAPIKeyStore(value: "keychain-secret")
        let settings = AssistantSettings(userDefaults: defaults, apiKeyStore: store)

        settings.apiKey = ""

        XCTAssertNil(store.value)
        XCTAssertEqual(store.deleteCallCount, 1)
        XCTAssertNil(defaults.object(forKey: Self.legacyDefaultsKey))
    }

    func testFailedKeychainDeletionIsVisibleAndRetryable() {
        let defaults = makeDefaults()
        let store = InMemoryAPIKeyStore(value: "keychain-secret")
        let settings = AssistantSettings(userDefaults: defaults, apiKeyStore: store)
        store.deleteError = TestStoreError.unavailable

        settings.apiKey = ""

        XCTAssertEqual(store.value, "keychain-secret", "A failed deletion must not be reported as success")
        XCTAssertNotNil(settings.apiKeyPersistenceError)
        XCTAssertNil(defaults.object(forKey: Self.legacyDefaultsKey))

        store.deleteError = nil
        settings.retryAPIKeyPersistence()

        XCTAssertNil(store.value)
        XCTAssertNil(settings.apiKeyPersistenceError)
        XCTAssertEqual(store.deleteCallCount, 2)
    }

    func testassistantInvocationKeepsPromptAndNoteContentOutOfArguments() {
        let noteSecret = "private-note-marker"
        let promptSecret = "private-prompt-marker"
        let arguments = assistantSubscriptionClient.processArguments()

        XCTAssertFalse(arguments.contains(where: { $0.contains(noteSecret) }))
        XCTAssertFalse(arguments.contains(where: { $0.contains(promptSecret) }))
        XCTAssertFalse(arguments.contains(where: { $0.contains("system-prompt") }))
        let input = String(
            data: assistantSubscriptionClient.standardInputData(
                for: promptSecret,
                systemPrompt: noteSecret
            ),
            encoding: .utf8
        )
        XCTAssertTrue(input?.contains(promptSecret) == true)
        XCTAssertTrue(input?.contains(noteSecret) == true)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AssistantSecurityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private enum TestStoreError: Error {
    case unavailable
}

private final class InMemoryAPIKeyStore: APIKeyStoring {
    var value: String?
    var readError: Error?
    var saveError: Error?
    var deleteError: Error?
    private(set) var saveCallCount = 0
    private(set) var deleteCallCount = 0

    init(value: String? = nil) {
        self.value = value
    }

    func read() throws -> String? {
        if let readError { throw readError }
        return value
    }

    func save(_ value: String) throws {
        saveCallCount += 1
        if let saveError { throw saveError }
        self.value = value
    }

    func delete() throws {
        deleteCallCount += 1
        if let deleteError { throw deleteError }
        value = nil
    }
}
