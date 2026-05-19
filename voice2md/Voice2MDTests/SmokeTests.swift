import XCTest
@testable import Voice2MD

final class SmokeTests: XCTestCase {
    func testTrue() {
        XCTAssertTrue(true)
    }

    func testKeychainRoundtrip() throws {
        let account = "test-roundtrip-\(UUID().uuidString)"
        Keychain.delete(account: account)
        XCTAssertNil(Keychain.read(account: account), "expected empty keychain at start")

        let writeStatus = Keychain.write("sk-test-roundtrip-1", account: account)
        XCTAssertEqual(writeStatus, errSecSuccess, "write should succeed")
        XCTAssertEqual(Keychain.read(account: account), "sk-test-roundtrip-1")

        Keychain.write("sk-test-roundtrip-2", account: account)
        XCTAssertEqual(Keychain.read(account: account), "sk-test-roundtrip-2", "second write should overwrite")

        Keychain.write("", account: account)
        XCTAssertNil(Keychain.read(account: account), "empty write should delete")
    }

    func testKeychainAccountsAreIndependent() {
        let a = "test-acc-A-\(UUID().uuidString)"
        let b = "test-acc-B-\(UUID().uuidString)"
        Keychain.write("alpha", account: a)
        Keychain.write("beta", account: b)
        XCTAssertEqual(Keychain.read(account: a), "alpha")
        XCTAssertEqual(Keychain.read(account: b), "beta")
        Keychain.delete(account: a)
        XCTAssertNil(Keychain.read(account: a))
        XCTAssertEqual(Keychain.read(account: b), "beta", "deleting one account should not touch the other")
        Keychain.delete(account: b)
    }

    func testAppConfigDefaults() {
        let suiteName = "AppConfigTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = AppConfig(defaults: defaults)
        XCTAssertEqual(config.aiProvider, .anthropic)
        XCTAssertEqual(config.claudeModel, "claude-haiku-4-5")
        XCTAssertEqual(config.whisperModel, "small.en")
        XCTAssertEqual(config.azureApiVersion, AppConfig.defaultAzureApiVersion)
        XCTAssertEqual(config.azureEndpoint, "")
        XCTAssertEqual(config.azureDeployment, "")
        XCTAssertTrue(config.extensionAllowlist.contains("m4a"))
        XCTAssertTrue(config.extensionAllowlist.contains("mp4"))
        XCTAssertFalse(config.paused)
    }
}
