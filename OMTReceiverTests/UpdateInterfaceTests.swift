import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class UpdateInterfaceTests: XCTestCase {
    func testSharedReminderKeepsNativeSourceControlsAndEditingFocus() async throws {
        let driver = InterfaceUpdateDriver()
        let updates = AppUpdateViewModel(driver: driver); updates.start()
        let discovery = OMTDiscoveryManager()
        let first = ReceiverWindowController(discovery: discovery, number: 921, updates: updates)
        let second = ReceiverWindowController(discovery: discovery, number: 922, updates: updates)
        XCTAssertNotEqual(first.window?.toolbar?.identifier, second.window?.toolbar?.identifier,
                          "Independent receiver items must not share an AppKit toolbar family")
        let settings = PreferencesWindowController(discovery: discovery, updates: updates)
        let window = try XCTUnwrap(first.window)
        window.setContentSize(NSSize(width: 680, height: 400))
        window.makeKeyAndOrderFront(nil)
        let table = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? NSCollectionView }.first)
        let muteItem = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "receiver.mute" })
        table.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: [])
        XCTAssertTrue(window.makeFirstResponder(table))
        let sourceResponder = window.firstResponder
        XCTAssertNil(badge(first)); XCTAssertNil(badge(second))

        driver.state.availableVersion = "1.2.345"
        let firstBadge = try XCTUnwrap(badge(first)), secondBadge = try XCTUnwrap(badge(second))
        XCTAssertTrue(firstBadge.label.contains("1.2.345"))
        XCTAssertTrue(secondBadge.label.contains("1.2.345"))
        XCTAssertTrue(firstBadge.isEnabled)
        XCTAssertTrue(window.firstResponder === sourceResponder)
        XCTAssertTrue(window.toolbar?.items.first { $0.itemIdentifier == muteItem.itemIdentifier } === muteItem)
        XCTAssertEqual(table.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        XCTAssertEqual(driver.checks, 0, "A scheduled reminder must not launch Sparkle UI")

        let content = try XCTUnwrap(settings.window?.contentView)
        let controls = descendants(content)
        let server = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "omt://discovery-server:6399" })
        settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
        server.stringValue = "omt://draft.local:6399"
        XCTAssertTrue(settings.window?.makeFirstResponder(server) == true)
        let editor = try XCTUnwrap(server.currentEditor())
        driver.state.canCheckForUpdates = false
        XCTAssertTrue(server.currentEditor() === editor)
        XCTAssertEqual(server.stringValue, "omt://draft.local:6399")
        XCTAssertFalse(firstBadge.isEnabled)
        XCTAssertNotNil(badge(second), "Unavailable controls must not hide an available update")
        XCTAssertTrue(firstBadge.toolTip?.contains("temporarily unavailable") == true)
        let check = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Check for Updates…" })
        XCTAssertFalse(check.isEnabled)
        driver.state.canCheckForUpdates = true
        check.performClick(nil)
        XCTAssertEqual(driver.checks, 1)
        XCTAssertFalse(check.isEnabled)

        await retire([first])
        driver.state.availableVersion = "2.0"
        XCTAssertTrue(badge(second)?.label.contains("2.0") == true)
        XCTAssertEqual(driver.starts, 1)
        driver.state.availableVersion = nil
        XCTAssertNil(badge(second))
        await retire([second])
        settings.window?.close()
    }

    func testSettingsUsesSharedAutomaticPreferenceAndKeepsControlsWithinLightAndDarkWindow() throws {
        let driver = InterfaceUpdateDriver()
        driver.state.automaticallyChecksForUpdates = false
        let updates = AppUpdateViewModel(driver: driver); updates.start()
        let settings = PreferencesWindowController(discovery: OMTDiscoveryManager(), updates: updates)
        defer { settings.window?.close() }
        let window = try XCTUnwrap(settings.window), content = try XCTUnwrap(window.contentView)
        let controls = descendants(content)
        let checkbox = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Automatically Check for Updates" })
        let check = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Check for Updates…" })
        XCTAssertEqual(checkbox.state, .off)
        checkbox.performClick(nil)
        XCTAssertTrue(driver.state.automaticallyChecksForUpdates)
        driver.state.automaticallyChecksForUpdates = false
        XCTAssertEqual(checkbox.state, .off)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            for view in [checkbox, check] {
                let frame = view.convert(view.bounds, to: content)
                XCTAssertGreaterThan(frame.width, 30)
                XCTAssertGreaterThan(frame.height, 10)
                XCTAssertTrue(content.bounds.contains(frame), "Update control is clipped: \(frame)")
            }
        }
        driver.state.startupError = "Updates unavailable: signing configuration is missing."
        driver.state.canCheckForUpdates = false
        XCTAssertFalse(check.isEnabled)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("signing configuration is missing") })
    }

    func testExplicitDialogsRevealStackedReceiversOnTheInvokingDisplay() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "A native display is required")
        let driver = InterfaceUpdateDriver()
        let updates = AppUpdateViewModel(driver: driver); updates.start()
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 923, updates: updates)
        let second = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 924, updates: updates)
        first.toggleFullscreen(nil); second.toggleFullscreen(nil)
        defer { first.revealControlsForDialog(); second.revealControlsForDialog() }
        let settings = PreferencesWindowController(discovery: OMTDiscoveryManager(), updates: updates)
        defer { settings.window?.close() }
        AppDelegate.revealControls(for: settings.window, receivers: [first, second])
        XCTAssertTrue(first.isFullscreen); XCTAssertTrue(second.isFullscreen)
        driver.state.availableVersion = "1.1"
        XCTAssertTrue(first.isFullscreen); XCTAssertTrue(second.isFullscreen)
        XCTAssertEqual(driver.checks, 0)
        let presentation = try XCTUnwrap(NSApp.windows.first { first.owns($0) && $0 !== first.window })
        XCTAssertEqual(first.fullscreenDisplayID, second.fullscreenDisplayID)
        let owner = try XCTUnwrap(first.window)
        let video = try XCTUnwrap(descendants(presentation.contentView!).compactMap { $0 as? VideoView }.first)
        // The app-unit host cannot force WindowServer foreground activation.
        // Supply the resolver's explicit key-window dependency and verify local
        // window/responder ownership; native foreground focus is a separate check.
        AppDelegate.revealControls(for: presentation, receivers: [first, second])
        XCTAssertFalse(first.isFullscreen)
        XCTAssertFalse(second.isFullscreen, "A stacked receiver must not obscure the native update dialog")
        XCTAssertTrue(owner.isVisible)
        XCTAssertTrue(owner.firstResponder === first.sourceBrowser.collectionView)
        XCTAssertTrue(video.window === owner)
        let item = try XCTUnwrap(badge(first))
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(driver.checks, 1)
        await retire([first, second])
    }

    func testExplicitDialogPreservesPresentationOnAnotherConnectedDisplay() async throws {
        guard let external = NSScreen.screens.first(where: { DisplayCatalog.displayID(for: $0) != CGMainDisplayID() }) else {
            throw XCTSkip("A second connected display is required")
        }
        let saved = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = saved }
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 925)
        let second = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 926)
        first.toggleFullscreen(nil); second.toggleFullscreen(nil)
        defer { first.revealControlsForDialog(); second.revealControlsForDialog() }
        let firstPresentation = try XCTUnwrap(NSApp.windows.first { first.owns($0) && $0 !== first.window })
        let secondPresentation = try XCTUnwrap(NSApp.windows.first { second.owns($0) && $0 !== second.window })
        // Grouping follows the actual windows even if a display or window move
        // has changed their location since the saved default was chosen.
        secondPresentation.setFrame(external.frame, display: true)
        XCTAssertNotEqual(first.fullscreenDisplayID, second.fullscreenDisplayID)
        let owner = try XCTUnwrap(first.window)
        let video = try XCTUnwrap(descendants(firstPresentation.contentView!).compactMap { $0 as? VideoView }.first)
        // Key-window input is injected because this component test does not own
        // OS foreground activation. Check the actual view and responder transfer.
        AppDelegate.revealControls(for: firstPresentation, receivers: [first, second])
        XCTAssertFalse(first.isFullscreen)
        XCTAssertTrue(owner.isVisible)
        XCTAssertTrue(owner.firstResponder === first.sourceBrowser.collectionView)
        XCTAssertTrue(video.window === owner)
        XCTAssertTrue(second.isFullscreen)
        XCTAssertEqual(second.fullscreenDisplayID, DisplayCatalog.identifier(for: external))
        await retire([first, second])
    }

    private func badge(_ controller: ReceiverWindowController) -> NSToolbarItem? {
        controller.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "receiver.update" }
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private func retire(_ controllers: [ReceiverWindowController]) async {
        let stopped = expectation(description: "Receiver workers retired")
        stopped.expectedFulfillmentCount = controllers.count
        controllers.forEach { $0.shutdown { stopped.fulfill() } }
        await fulfillment(of: [stopped], timeout: 5)
        controllers.forEach { $0.window?.close() }
    }
}

@MainActor
private final class InterfaceUpdateDriver: AppUpdateDriving {
    var state = AppUpdateState() { didSet { onStateChange?(state) } }
    var onStateChange: ((AppUpdateState) -> Void)?
    var starts = 0
    var checks = 0
    func start() { starts += 1; state.canCheckForUpdates = true }
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false }
    func setAutomaticChecks(_ enabled: Bool) { state.automaticallyChecksForUpdates = enabled }
}
