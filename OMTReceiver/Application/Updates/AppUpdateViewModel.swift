import Foundation

struct AppUpdateState: Equatable {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = true
    var availableVersion: String?
    var startupError: String?
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var state: AppUpdateState { get }
    var onStateChange: ((AppUpdateState) -> Void)? { get set }
    func start()
    func checkForUpdates()
    func setAutomaticChecks(_ enabled: Bool)
}

extension Notification.Name {
    /// Posted on the main actor with the app-owned AppUpdateViewModel as object.
    /// Each window and Settings can observe independently without owning Sparkle.
    static let receiverUpdateStateChanged = Notification.Name("ReceiverUpdateStateChanged")
}

/// One updater for the application. Closing a receiver or Settings does not end
/// its update session, and a scheduled reminder never starts an install itself.
@MainActor
final class AppUpdateViewModel: NSObject {
    private(set) var state: AppUpdateState
    var onChange: (() -> Void)?
    private let driver: any AppUpdateDriving
    private var started = false

    init(driver: any AppUpdateDriving) {
        self.driver = driver
        state = driver.state
        super.init()
        driver.onStateChange = { [weak self] state in
            guard let self, self.state != state else { return }
            self.state = state
            NotificationCenter.default.post(name: .receiverUpdateStateChanged, object: self)
            self.onChange?()
        }
    }

    var canCheckForUpdates: Bool { state.canCheckForUpdates }
    var isUpdateAvailable: Bool { state.availableVersion != nil }
    var availableVersion: String? { state.availableVersion }
    var startupError: String? { state.startupError }
    var automaticallyChecksForUpdates: Bool {
        get { state.automaticallyChecksForUpdates }
        set { setAutomaticChecks(newValue) }
    }

    func start() {
        guard !started else { return }
        started = true
        driver.start()
    }

    func checkForUpdates() {
        guard state.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        driver.setAutomaticChecks(enabled)
    }
}
