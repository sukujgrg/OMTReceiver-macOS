import Foundation
import Sparkle

/// Sparkle owns its native dialogs, verification, download, installation and
/// relaunch. In particular, relaunch uses NSApplication's normal termination
/// path, which lets the app finish stopping all receiver and discovery workers.
@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriving,
    @preconcurrency SPUStandardUserDriverDelegate {
    var onStateChange: ((AppUpdateState) -> Void)?
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var availableVersion: String?
    private var startupError: String?
    private var started = false
    private var pendingAutomaticChecks: Bool?

    var state: AppUpdateState {
        AppUpdateState(
            canCheckForUpdates: startupError == nil && (controller?.updater.canCheckForUpdates ?? false),
            automaticallyChecksForUpdates: controller?.updater.automaticallyChecksForUpdates ?? pendingAutomaticChecks ?? true,
            availableVersion: availableVersion,
            startupError: startupError
        )
    }

    func start() {
        guard !started else { return }
        started = true
        // Construct only on explicit start. A hosted XCTest launch can create an
        // app delegate/model without touching a live updater or network feed.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
        )
        self.controller = controller
        let updater = controller.updater
        if let pendingAutomaticChecks {
            updater.automaticallyChecksForUpdates = pendingAutomaticChecks
        }
        // Receiving a live stream must never trigger an unattended install.
        // Info.plist also disallows automatic downloads/installation.
        updater.automaticallyDownloadsUpdates = false
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishState() }
            }
        ]
        do {
            // The controller's wrapper logs and displays a delayed alert for
            // configuration errors. Starting its updater directly lets Settings
            // show that error without interrupting an active video output.
            try updater.start()
        } catch {
            startupError = "Updates unavailable: \(error.localizedDescription)"
        }
        publishState()
    }

    func checkForUpdates() {
        guard state.canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        pendingAutomaticChecks = enabled
        controller?.updater.automaticallyChecksForUpdates = enabled
        publishState()
    }

    private func publishState() { onStateChange?(state) }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Even a scheduled check near launch must not steal focus from live
        // video or projection. The shared model publishes a native toolbar badge.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        availableVersion = update.displayVersionString
        publishState()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        publishState()
    }
}
