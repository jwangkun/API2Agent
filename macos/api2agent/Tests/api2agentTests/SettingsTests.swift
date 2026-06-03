import api2agentCore
import XCTest

final class SettingsTests: XCTestCase {
    func testSettingsDecodeOldPersistedShapeWithoutKeychainMarker() throws {
        let data = Data("""
        {
          "port": 9999,
          "api2agentBaseURL": "",
          "backendBaseURL": "",
          "localAgentEndpoint": "",
          "clientVersion": "sdk-1.0.13",
          "launchAtLogin": false
        }
        """.utf8)

        let settings = try JSONDecoder().decode(api2agentSettings.self, from: data)

        XCTAssertEqual(settings.port, 9999)
        XCTAssertFalse(settings.hasapi2agentKey)
        XCTAssertFalse(settings.keychainapi2agentKeyAvailable)
        XCTAssertFalse(settings.menuBarOnly)
    }

    func testKeychainAvailabilityCountsAsSavedAPIKeyWithoutSecretInMemory() {
        let settings = api2agentSettings(api2agentKey: "", keychainapi2agentKeyAvailable: true)

        XCTAssertTrue(settings.hasapi2agentKey)
        XCTAssertFalse(settings.hasInlineapi2agentKey)
    }

    func testRoutingConfigurationDoesNotRequireAPIKey() {
        let settings = api2agentSettings(
            api2agentKey: "",
            api2agentBaseURL: "https://exchange.example",
            backendBaseURL: "https://routing.example",
            localAgentEndpoint: "/sdk/run"
        )

        XCTAssertFalse(settings.hasapi2agentKey)
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testSDKConfigurationNoLongerRequiresKeyExchangeOrigin() {
        let settings = api2agentSettings(
            api2agentKey: "",
            backendBaseURL: "https://routing.example",
            localAgentEndpoint: "/sdk/run"
        )

        XCTAssertFalse(settings.hasapi2agentExchangeConfiguration)
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testLegacyapi2agentBaseURLDoesNotBlockLocalSDKBridge() {
        let settings = api2agentSettings(
            api2agentKey: "",
            api2agentBaseURL: api2agentSettings.legacyapi2agentBaseURL,
            backendBaseURL: "https://routing.example",
            localAgentEndpoint: "/sdk/run"
        )

        XCTAssertFalse(settings.hasapi2agentExchangeConfiguration)
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testSettingsEncodingDoesNotPersistKeychainAvailabilityMarker() throws {
        var settings = api2agentSettings(keychainapi2agentKeyAvailable: true)
        settings.api2agentKey = ""

        let data = try JSONEncoder.api2agentPretty.encode(settings)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("keychainapi2agentKeyAvailable"))
        XCTAssertTrue(text.contains("\"menuBarOnly\""))
    }

    func testBundledTransportDefaultsFillMissingSDKSettings() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: {
                [
                    "api2agentBaseURL": "https://exchange.example",
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.api2agentBaseURL, "https://exchange.example")
        XCTAssertEqual(settings.backendBaseURL, "https://bundled.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/sdk/run")
        XCTAssertEqual(settings.clientVersion, "sdk-test")
        XCTAssertTrue(settings.hasCursorSDKConfiguration)
    }

    func testEnvironmentOverridesBundledTransportDefaults() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [
                "CURSOR_API_BASE": "https://exchange-env.example",
                "CURSOR_BACKEND_BASE_URL": "https://env.example",
                "CURSOR_LOCAL_AGENT_ENDPOINT": "/env/run",
                "CURSOR_SDK_CLIENT_VERSION": "sdk-env"
            ],
            bundledTransportDefaults: {
                [
                    "api2agentBaseURL": "https://exchange-bundled.example",
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.api2agentBaseURL, "https://exchange-env.example")
        XCTAssertEqual(settings.backendBaseURL, "https://env.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/env/run")
        XCTAssertEqual(settings.clientVersion, "sdk-env")
    }

    func testEnvironmentDoesNotLoadapi2agentKey() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [
                "CURSOR_API_KEY": "crsr_env_should_not_be_loaded"
            ],
            bundledTransportDefaults: { [:] },
            keychainService: "api2agent.SettingsTests.\(UUID().uuidString)",
            legacyKeychainServices: [],
            keychainAccount: "cursor-api-key"
        )

        let settings = store.load()

        XCTAssertEqual(settings.api2agentKey, "")
        XCTAssertFalse(settings.hasapi2agentKey)
    }

    func testSavedAPIKeyUsesRenamedKeychainService() throws {
        let defaults = isolatedDefaults()
        let keychainService = "ai.standardagents.apiforcursor.SettingsTests.\(UUID().uuidString)"
        let legacyKeychainService = "ai.standardagents.api2agent.SettingsTests.\(UUID().uuidString)"
        let account = "cursor-api-key-\(UUID().uuidString)"
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [legacyKeychainService],
            keychainAccount: account
        )
        defer { store.save(api2agentSettings(api2agentKey: "", keychainapi2agentKeyAvailable: false)) }

        store.save(api2agentSettings(api2agentKey: " crsr_saved "))

        let settings = store.load()
        XCTAssertEqual(settings.api2agentKey, "")
        XCTAssertTrue(settings.hasapi2agentKey)

        let resolved = try store.resolvingapi2agentKey(in: settings, allowUserPrompt: false)
        XCTAssertEqual(resolved.api2agentKey, "crsr_saved")

        let primaryOnlyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        XCTAssertTrue(primaryOnlyStore.load().hasapi2agentKey)

        let legacyOnlyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: legacyKeychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        XCTAssertFalse(legacyOnlyStore.load().hasapi2agentKey)
    }

    func testLegacyKeychainServiceMigratesToRenamedService() throws {
        let keychainService = "ai.standardagents.apiforcursor.SettingsTests.\(UUID().uuidString)"
        let legacyKeychainService = "ai.standardagents.api2agent.SettingsTests.\(UUID().uuidString)"
        let account = "cursor-api-key-\(UUID().uuidString)"
        let legacyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: legacyKeychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        let store = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [legacyKeychainService],
            keychainAccount: account
        )
        defer { store.save(api2agentSettings(api2agentKey: "", keychainapi2agentKeyAvailable: false)) }

        legacyStore.save(api2agentSettings(api2agentKey: "crsr_legacy"))

        let settings = store.load()
        XCTAssertTrue(settings.hasapi2agentKey)

        let resolved = try store.resolvingapi2agentKey(in: settings, allowUserPrompt: false)
        XCTAssertEqual(resolved.api2agentKey, "crsr_legacy")

        let primaryOnlyStore = AppSettingsStore(
            defaults: isolatedDefaults(),
            environment: [:],
            bundledTransportDefaults: { [:] },
            keychainService: keychainService,
            legacyKeychainServices: [],
            keychainAccount: account
        )
        XCTAssertTrue(primaryOnlyStore.load().hasapi2agentKey)
        XCTAssertFalse(legacyStore.load().hasapi2agentKey)
    }

    func testSavedTransportSettingsOverrideBundledDefaults() throws {
        let defaults = isolatedDefaults()
        let saved = api2agentSettings(
            port: 8787,
            api2agentKey: "",
            api2agentBaseURL: "https://exchange-saved.example",
            backendBaseURL: "https://saved.example",
            localAgentEndpoint: "/saved/run",
            clientVersion: "sdk-saved",
            launchAtLogin: false
        )
        let data = try JSONEncoder.api2agentPretty.encode(saved)
        defaults.set(data, forKey: "api2agent.settings.v1")
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: {
                [
                    "api2agentBaseURL": "https://exchange-bundled.example",
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.api2agentBaseURL, "https://exchange-saved.example")
        XCTAssertEqual(settings.backendBaseURL, "https://saved.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/saved/run")
        XCTAssertEqual(settings.clientVersion, "sdk-saved")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "api2agent.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
