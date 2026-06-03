import XCTest
@testable import api2agent
import api2agentCore

final class AppModelTests: XCTestCase {
    func testInstallAllTitleDoesNotRequireUnlockWhenSavedKeyIsLocked() {
        let statuses = [
            AgentIntegrationStatus(
                id: .opencode,
                installed: false,
                configPath: nil,
                detail: "Provider points at a hosted API"
            )
        ]

        XCTAssertEqual(
            api2agentAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: true,
                needsKeychainPermission: true
            ),
            "Update All"
        )
    }

    func testInstallAllTitleUsesStartOnlyWhenServerIsStoppedAndKeyIsUnlocked() {
        let statuses = [
            AgentIntegrationStatus(
                id: .codex,
                installed: false,
                configPath: nil,
                detail: "Ready to install"
            )
        ]

        XCTAssertEqual(
            api2agentAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: false,
                needsKeychainPermission: false
            ),
            "Start & Install All"
        )
    }

    func testInstallAllTitleOmitsPrefixWhenServerIsReady() {
        let statuses = [
            AgentIntegrationStatus(
                id: .codex,
                installed: false,
                configPath: nil,
                detail: "Ready to install"
            )
        ]

        XCTAssertEqual(
            api2agentAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: true,
                needsKeychainPermission: false
            ),
            "Install All"
        )
    }

    func testIntegrationActionTitleDoesNotRequireUnlockWhenSavedKeyIsLocked() {
        let status = AgentIntegrationStatus(
            id: .opencode,
            installed: false,
            configPath: nil,
            detail: "Provider points at a hosted API"
        )

        XCTAssertEqual(
            api2agentAppModel.actionTitle(
                for: status,
                isRunning: true,
                needsKeychainPermission: true
            ),
            "Update"
        )
    }

    func testIntegrationActionTitleDoesNotPrefixStartBecauseServerAutostarts() {
        let status = AgentIntegrationStatus(
            id: .codex,
            installed: false,
            configPath: nil,
            detail: "Ready to install"
        )

        XCTAssertEqual(
            api2agentAppModel.actionTitle(
                for: status,
                isRunning: false,
                needsKeychainPermission: false
            ),
            "Install"
        )
    }

    func testIntegrationActionTitlePreservesTerminalStates() {
        let installed = AgentIntegrationStatus(
            id: .codex,
            installed: true,
            configPath: nil,
            detail: "Custom provider installed"
        )
        let unavailable = AgentIntegrationStatus(
            id: .cline,
            installed: false,
            configPath: nil,
            detail: "Extension state not found",
            canInstall: false
        )

        XCTAssertEqual(
            api2agentAppModel.actionTitle(
                for: installed,
                isRunning: false,
                needsKeychainPermission: true
            ),
            "Installed"
        )
        XCTAssertEqual(
            api2agentAppModel.actionTitle(
                for: unavailable,
                isRunning: false,
                needsKeychainPermission: true
            ),
            "Unavailable"
        )
    }
}
