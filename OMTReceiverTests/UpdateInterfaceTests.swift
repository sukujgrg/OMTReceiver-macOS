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
        XCTAssertEqual(Set(controls.compactMap { ($0 as? NSPopUpButton)?.accessibilityLabel() }),
                       ["Default fullscreen display", "Interlaced video", "Field order", "Alpha background"])
        for (label, value) in [("Interlaced video", Preferences.shared.deinterlace.title),
                               ("Field order", Preferences.shared.fieldOrder.title),
                               ("Alpha background", Preferences.shared.background.title)] {
            let popup = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == label })
            // A single-cell NSControl exposes its cell to accessibility clients.
            // The outer NSPopUpButton's default value getter is intentionally nil.
            let accessible = try XCTUnwrap(NSAccessibility.unignoredDescendant(of: popup) as? NSAccessibilityProtocol)
            XCTAssertEqual(accessible.accessibilityRole(), .popUpButton)
            XCTAssertEqual(accessible.accessibilityValue() as? String, value,
                           "The native accessible popup must expose its current selection")
            let originalSelection = popup.indexOfSelectedItem
            popup.selectItem(at: (originalSelection + 1) % popup.numberOfItems)
            XCTAssertEqual(accessible.accessibilityValue() as? String, popup.titleOfSelectedItem,
                           "AppKit must update the exposed selection without a manually cached accessibility value")
            popup.selectItem(at: originalSelection)
        }
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

    func testDisplayOwnershipReplacementAndExplicitDialogsRevealControls() async throws {
        let screen = try XCTUnwrap(DisplayCatalog.mainScreen)
        let driver = InterfaceUpdateDriver()
        let updates = AppUpdateViewModel(driver: driver); updates.start()
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 923, updates: updates, screens: { [screen] })
        let second = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 924, updates: updates, screens: { [screen] })
        // This case requires controls and output on the same display. AppKit's
        // default placement follows the key window left by earlier tests.
        for controller in [first, second] {
            controller.window?.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
            XCTAssertEqual(controller.window?.screen.map(DisplayCatalog.identifier), DisplayCatalog.identifier(for: screen))
        }
        first.toggleFullscreen(nil); second.toggleFullscreen(nil)
        defer { first.revealControlsForDialog(); second.revealControlsForDialog() }
        let settings = PreferencesWindowController(discovery: OMTDiscoveryManager(), updates: updates)
        defer { settings.window?.close() }
        AppDelegate.revealControls(for: settings.window, receivers: [first, second])
        XCTAssertFalse(first.isFullscreen)
        XCTAssertNil(first.selectedSource, "Displaced video/audio reception must stop")
        XCTAssertTrue(second.isFullscreen)
        driver.state.availableVersion = "1.1"
        XCTAssertFalse(first.isFullscreen)
        XCTAssertNil(first.selectedSource, "Displaced video/audio reception must stop")
        XCTAssertTrue(second.isFullscreen)
        XCTAssertEqual(driver.checks, 0)
        let presentation = try XCTUnwrap(NSApp.windows.first { second.owns($0) && $0 !== second.window })
        let owner = try XCTUnwrap(second.window)
        let video = try XCTUnwrap(descendants(presentation.contentView!).compactMap { $0 as? VideoView }.first)
        // The app-unit host cannot force WindowServer foreground activation.
        // Supply the resolver's explicit key-window dependency and verify local
        // window/responder ownership; native foreground focus is a separate check.
        AppDelegate.revealControls(for: presentation, receivers: [first, second])
        XCTAssertFalse(first.isFullscreen)
        XCTAssertTrue(second.isFullscreen, "Revealing controls must preserve the output session")
        XCTAssertEqual(second.selectedSource, .testPattern)
        XCTAssertEqual(presentation.level, .normal, "Native dialogs must be able to cover output on their display")
        XCTAssertTrue(owner.isVisible)
        XCTAssertTrue(owner.firstResponder === second.sourceBrowser.collectionView)
        XCTAssertTrue(video.window === presentation)
        second.sourceBrowser.onActivate?(.testPattern)
        XCTAssertTrue(second.owns(presentation), "Returning from controls reuses the same output")
        let item = try XCTUnwrap(badge(first))
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(driver.checks, 1)
        first.sourceBrowser.onActivate?(.testPattern)
        second.sourceBrowser.onActivate?(.testPattern)
        first.sourceBrowser.onActivate?(.testPattern)
        XCTAssertTrue(first.isFullscreen, "The most recently activated source must own the display")
        XCTAssertEqual(first.selectedSource, .testPattern)
        XCTAssertFalse(second.isFullscreen)
        XCTAssertNil(second.selectedSource, "The replaced receiver cannot retain hidden audio")
        await retire([first, second])
    }

    func testExplicitDialogPreservesPresentationOnAnotherConnectedDisplay() async throws {
        guard let external = NSScreen.screens.first(where: { DisplayCatalog.displayID(for: $0) != CGMainDisplayID() }) else {
            throw XCTSkip("A second connected display is required")
        }
        let saved = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = saved }
        let main = try XCTUnwrap(DisplayCatalog.mainScreen)
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 925, screens: { [main] })
        let second = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 926, screens: { [external] })
        for controller in [first, second] {
            controller.window?.setFrameOrigin(NSPoint(x: main.visibleFrame.minX + 40, y: main.visibleFrame.minY + 40))
        }
        first.toggleFullscreen(nil); second.toggleFullscreen(nil)
        defer { first.revealControlsForDialog(); second.revealControlsForDialog() }
        let firstPresentation = try XCTUnwrap(NSApp.windows.first { first.owns($0) && $0 !== first.window })
        let secondPresentation = try XCTUnwrap(NSApp.windows.first { second.owns($0) && $0 !== second.window })
        XCTAssertEqual(secondPresentation.level, .screenSaver, "External projection keeps its dedicated display policy")
        XCTAssertNotEqual(first.fullscreenDisplayID, second.fullscreenDisplayID)
        let owner = try XCTUnwrap(first.window)
        let video = try XCTUnwrap(descendants(firstPresentation.contentView!).compactMap { $0 as? VideoView }.first)
        // Key-window input is injected because this component test does not own
        // OS foreground activation. Check the actual view and responder transfer.
        AppDelegate.revealControls(for: firstPresentation, receivers: [first, second])
        XCTAssertTrue(first.isFullscreen)
        XCTAssertEqual(first.selectedSource, .testPattern)
        XCTAssertTrue(owner.isVisible)
        XCTAssertTrue(owner.firstResponder === first.sourceBrowser.collectionView)
        XCTAssertTrue(video.window === firstPresentation)
        XCTAssertTrue(second.isFullscreen)
        XCTAssertEqual(second.fullscreenDisplayID, DisplayCatalog.identifier(for: external))
        await retire([first, second])
    }

    func testShowSourcesRevealsBrowserCoveredByAnotherReceiversProjection() async throws {
        let main = try XCTUnwrap(DisplayCatalog.mainScreen)
        guard let target = NSScreen.screens.first(where: { DisplayCatalog.identifier(for: $0) != DisplayCatalog.identifier(for: main) }) else {
            throw XCTSkip("A second display is required for a browser covered by another receiver's projection")
        }
        let saved = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = DisplayCatalog.identifier(for: target)
        let browser = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 927)
        let playing = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 928)
        defer {
            browser.onRevealControls = nil
            browser.shutdown {}; playing.shutdown {}
            browser.window?.close(); playing.window?.close()
            Preferences.shared.fullscreenDisplayID = saved
        }
        let browserWindow = try XCTUnwrap(browser.window), controlsWindow = try XCTUnwrap(playing.window)
        browserWindow.setFrameOrigin(NSPoint(x: target.visibleFrame.minX + 40, y: target.visibleFrame.minY + 40))
        controlsWindow.setFrameOrigin(NSPoint(x: main.visibleFrame.minX + 40, y: main.visibleFrame.minY + 40))
        browser.showWindow(nil); playing.showWindow(nil)
        playing.connect(.testPattern)
        let output = try XCTUnwrap(NSApp.windows.first { playing.owns($0) && $0 !== controlsWindow })
        let video = try XCTUnwrap(descendants(output.contentView!).compactMap { $0 as? VideoView }.first)
        XCTAssertEqual(browserWindow.screen.map(DisplayCatalog.identifier), DisplayCatalog.identifier(for: target))
        XCTAssertEqual(output.screen.map(DisplayCatalog.identifier), DisplayCatalog.identifier(for: target))
        XCTAssertEqual(output.level, .screenSaver)
        var reveals = 0
        browser.onRevealControls = { [weak browser, weak playing] invoking in
            reveals += 1
            XCTAssertTrue(invoking === browserWindow)
            guard let browser, let playing else { XCTFail("Both receivers must survive the Sources command"); return }
            AppDelegate.revealControls(for: invoking, receivers: [browser, playing])
        }

        // Invoke the actual receiver command; directly calling revealControls
        // would conceal a regression in the command's application-level route.
        browser.toggleSidebar(nil)
        XCTAssertEqual(reveals, 1)
        XCTAssertTrue(playing.isFullscreen)
        XCTAssertEqual(playing.selectedSource, .testPattern, "Showing another browser cannot stop the active source or audio")
        XCTAssertTrue(video.window === output, "The presentation keeps the same full-quality surface")
        XCTAssertEqual(output.level, .normal, "The covering projection yields to native controls on its display")
        XCTAssertTrue(browserWindow.firstResponder === browser.sourceBrowser.collectionView)
        let order = NSApp.orderedWindows
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex { $0 === browserWindow }),
                          try XCTUnwrap(order.firstIndex { $0 === output }),
                          "The invoking source browser must be in front of the covering output")
        await retire([browser, playing])
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
