import Foundation
import XCTest
@testable import OMTReceiver

@MainActor
final class UpdateTests: XCTestCase {
    func testStartIsAppOwnedAndChecksFollowActualDriverCapability() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 0)
        updater.start(); updater.start()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updater.canCheckForUpdates)

        updater.checkForUpdates(); updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        XCTAssertFalse(updater.canCheckForUpdates)
        driver.state.canCheckForUpdates = true
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 2)
    }

    func testAutomaticCheckPreferenceUsesDriversPersistedValue() {
        let driver = UpdateDriverFixture()
        driver.state.automaticallyChecksForUpdates = false
        let updater = AppUpdateViewModel(driver: driver)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = true
        XCTAssertTrue(driver.state.automaticallyChecksForUpdates)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        driver.state.automaticallyChecksForUpdates = false
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }

    func testScheduledReminderDoesNotCheckOrInstallAndSurvivesWindowClosure() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver)
        updater.start()
        var firstVersions: [String?] = []
        var secondVersions: [String?] = []
        let first = NotificationCenter.default.addObserver(
            forName: .receiverUpdateStateChanged, object: updater, queue: .main
        ) { _ in MainActor.assumeIsolated { firstVersions.append(updater.availableVersion) } }
        let second = NotificationCenter.default.addObserver(
            forName: .receiverUpdateStateChanged, object: updater, queue: .main
        ) { _ in MainActor.assumeIsolated { secondVersions.append(updater.availableVersion) } }
        defer { NotificationCenter.default.removeObserver(second) }

        driver.state.availableVersion = "1.1"
        XCTAssertTrue(updater.isUpdateAvailable)
        XCTAssertEqual(firstVersions.last!, "1.1")
        XCTAssertEqual(secondVersions.last!, "1.1")
        XCTAssertEqual(driver.checks, 0, "A scheduled badge must not open the updater")
        NotificationCenter.default.removeObserver(first)
        driver.state.availableVersion = nil
        XCTAssertEqual(firstVersions.last!, "1.1")
        XCTAssertNil(secondVersions.last!)
        XCTAssertFalse(updater.isUpdateAvailable)
        XCTAssertEqual(driver.starts, 1)
    }

    func testUnchangedStateDoesNotRebuildNativeControls() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateViewModel(driver: driver)
        var notifications = 0
        updater.onChange = { notifications += 1 }
        driver.onStateChange?(driver.state)
        XCTAssertEqual(notifications, 0)
        driver.state.availableVersion = "1.1"
        XCTAssertEqual(notifications, 1)
        driver.onStateChange?(driver.state)
        XCTAssertEqual(notifications, 1)
    }

    func testStartupFailureIsVisibleWithoutEnablingAManualCheck() {
        let driver = UpdateDriverFixture()
        driver.failureOnStart = "Updates unavailable: invalid signing configuration"
        let updater = AppUpdateViewModel(driver: driver)
        updater.start()
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.startupError, driver.failureOnStart)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 0)
    }
}

@MainActor
private final class UpdateDriverFixture: AppUpdateDriving {
    var state = AppUpdateState() { didSet { onStateChange?(state) } }
    var onStateChange: ((AppUpdateState) -> Void)?
    var starts = 0
    var checks = 0
    var failureOnStart: String?
    func start() {
        starts += 1
        state.startupError = failureOnStart
        state.canCheckForUpdates = failureOnStart == nil
    }
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false }
    func setAutomaticChecks(_ enabled: Bool) { state.automaticallyChecksForUpdates = enabled }
}
