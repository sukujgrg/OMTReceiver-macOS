import AppKit
import XCTest
@testable import OMTReceiver

final class InterfaceTests: XCTestCase {
    @MainActor
    func testReceiverWindowsHaveIndependentSelectionAndMute() async throws {
        let discovery = OMTDiscoveryManager()
        let first = ReceiverWindowController(discovery: discovery, number: 801)
        let second = ReceiverWindowController(discovery: discovery, number: 802)
        XCTAssertNotIdentical(first.window, second.window)
        XCTAssertNil(first.selectedSource)
        XCTAssertNil(second.selectedSource)
        first.connect(.testPattern)
        second.connect(.testPattern)
        first.toggleMute(nil)
        XCTAssertTrue(first.muted)
        XCTAssertFalse(second.muted)
        let manual = try OMTSource.manual("omt://127.0.0.1:1")
        first.connect(manual)
        XCTAssertEqual(first.selectedSource, manual)
        XCTAssertEqual(second.selectedSource, .testPattern)
        first.disconnect(nil)
        XCTAssertNil(first.selectedSource)
        XCTAssertEqual(second.selectedSource, .testPattern)
        let stopped = expectation(description: "Both receiver workers retired")
        stopped.expectedFulfillmentCount = 2
        first.shutdown { stopped.fulfill() }
        second.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        first.window?.close(); second.window?.close()
    }

    @MainActor
    func testNativeFullscreenReturnsSameVideoSurfaceAndWindowGeometry() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "A native screen is required for the fullscreen lifecycle check")
        let saved = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = saved }
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 803)
        let window = try XCTUnwrap(receiver.window)
        let originalFrame = window.frame
        let video = try XCTUnwrap(descendants(of: window.contentView!).compactMap { $0 as? VideoView }.first)
        let normalParent = try XCTUnwrap(video.superview)
        receiver.toggleFullscreen(nil)
        XCTAssertTrue(receiver.isFullscreen)
        XCTAssertFalse(video.window === window)
        XCTAssertEqual(video.window?.styleMask, .borderless)
        XCTAssertEqual(video.window?.frame, DisplayCatalog.mainScreen?.frame)
        XCTAssertFalse(video.superview === normalParent)
        video.onEscape?()
        XCTAssertFalse(receiver.isFullscreen)
        XCTAssertTrue(video.window === window)
        XCTAssertTrue(video.superview === normalParent)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertNil(receiver.selectedSource, "Escape stops full-quality output and returns to the source grid")
        XCTAssertTrue(window.firstResponder === receiver.sourceBrowser.collectionView)
        let stopped = expectation(description: "Fullscreen receiver retired")
        receiver.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        window.close()
    }

    @MainActor
    func testSourceBrowserAndNativeSettingsRemainUsableAtMinimumSize() async throws {
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 804)
        let window = try XCTUnwrap(receiver.window)
        receiver.showWindow(nil)
        window.setContentSize(NSSize(width: 680, height: 430))
        window.contentView?.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(of: window.contentView!).compactMap { $0 as? NSCollectionView }.first)
        XCTAssertGreaterThanOrEqual(table.numberOfItems(inSection: 0), 1)
        table.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: [])
        XCTAssertEqual(table.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        XCTAssertGreaterThan(table.visibleRect.width, 100)
        XCTAssertNil(receiver.selectedSource)
        receiver.sourceBrowser.onActivate?(.testPattern)
        XCTAssertEqual(receiver.selectedSource, .testPattern)
        XCTAssertTrue(receiver.isFullscreen)
        XCTAssertTrue(window.isVisible, "The browser stays available while output is fullscreen")
        let settings = PreferencesWindowController(discovery: OMTDiscoveryManager())
        let content = try XCTUnwrap(settings.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let controls = descendants(of: content)
        XCTAssertEqual(controls.compactMap { $0 as? NSPopUpButton }.count, 4)
        XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "omt://discovery-server:6399" })
        XCTAssertTrue(controls.compactMap { $0 as? NSButton }.contains { $0.title == "Apply" })
        for control in controls where control is NSPopUpButton {
            XCTAssertGreaterThan(control.frame.width, 30)
            XCTAssertGreaterThan(control.frame.height, 10)
        }
        let stopped = expectation(description: "Browser receiver retired")
        receiver.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 5)
        window.close(); settings.window?.close()
    }

    @MainActor
    func testFullscreenWindowInitializesOnEveryConnectedScreenBeforeVideoAttach() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "A native screen is required")
        for screen in NSScreen.screens {
            let window = PresentationWindow(on: screen)
            defer { window.close() }
            // This assertion catches double-adding an external display's origin
            // before a later setFrame can conceal the initialization error.
            XCTAssertEqual(window.frame, screen.frame, screen.localizedName)
            XCTAssertEqual(window.screen.map(DisplayCatalog.identifier), DisplayCatalog.identifier(for: screen))
            XCTAssertEqual(window.level, .screenSaver)
            XCTAssertFalse(window.isRestorable)
        }
    }

    func testScreenRelativeInitializationSupportsNegativeAndVerticalOrigins() {
        for frame in [NSRect(x: -1920, y: 0, width: 1920, height: 1080),
                      NSRect(x: 2560, y: -500, width: 1920, height: 1080),
                      NSRect(x: 0, y: 1440, width: 2560, height: 1440)] {
            XCTAssertEqual(DisplayCatalog.screenRelativeContentRect(for: frame), NSRect(origin: .zero, size: frame.size))
        }
    }

    @MainActor
    func testFullscreenPreferenceMovesSameSurfaceToExternalDisplay() throws {
        guard let external = NSScreen.screens.first(where: { DisplayCatalog.displayID(for: $0) != CGMainDisplayID() }) else { throw XCTSkip("A second connected display is required") }
        let saved = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = saved }
        let home = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let owner = NSWindow(contentRect: home.frame, styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.contentView = home
        let video = VideoView(frame: home.bounds); home.addSubview(video)
        let controller = FullscreenController(owner: owner, home: home, video: video)
        defer { controller.exit(showOwner: false); owner.close() }
        let normalFrame = owner.frame
        controller.enter()
        XCTAssertEqual(video.window?.frame, DisplayCatalog.mainScreen?.frame)
        Preferences.shared.fullscreenDisplayID = DisplayCatalog.identifier(for: external)
        XCTAssertTrue(controller.isFullscreen)
        XCTAssertEqual(video.window?.frame, external.frame)
        XCTAssertEqual(video.window?.screen.map(DisplayCatalog.identifier), DisplayCatalog.identifier(for: external))
        XCTAssertTrue(video.window?.isVisible == true)
        XCTAssertEqual(video.frame.size, external.frame.size)
        controller.exit()
        XCTAssertTrue(video.window === owner)
        XCTAssertEqual(owner.frame, normalFrame)
    }

    @MainActor
    func testTargetRemovalRestoresSurfaceAndRetainsChosenUUID() throws {
        let screen = try XCTUnwrap(NSScreen.screens.last)
        let saved = Preferences.shared.fullscreenDisplayID
        let target = DisplayCatalog.identifier(for: screen)
        Preferences.shared.fullscreenDisplayID = target
        defer { Preferences.shared.fullscreenDisplayID = saved }
        var available = NSScreen.screens
        let home = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let owner = NSWindow(contentRect: home.frame, styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; owner.contentView = home
        let video = VideoView(frame: home.bounds); home.addSubview(video)
        let controller = FullscreenController(owner: owner, home: home, video: video, screens: { available })
        defer { controller.exit(showOwner: false); owner.close() }
        controller.enter()
        XCTAssertTrue(controller.isFullscreen)
        available.removeAll { DisplayCatalog.identifier(for: $0) == target }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        XCTAssertFalse(controller.isFullscreen)
        XCTAssertTrue(video.window === owner)
        XCTAssertEqual(Preferences.shared.fullscreenDisplayID, target)
        XCTAssertNil(DisplayCatalog.target(identifier: target, screens: []))
        XCTAssertEqual(DisplayCatalog.target(identifier: target, screens: available).map(DisplayCatalog.identifier),
                       available.first.map(DisplayCatalog.identifier))
    }

    @MainActor
    func testGridActivationSwitchesExistingOutputAndRetargetDoesNotDisconnect() async throws {
        guard let external = NSScreen.screens.first(where: { DisplayCatalog.displayID(for: $0) != CGMainDisplayID() }) else { throw XCTSkip("A second display is required") }
        let saved = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = saved }
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 805)
        receiver.showWindow(nil)
        receiver.sourceBrowser.onActivate?(.testPattern)
        let output = try XCTUnwrap(NSApp.windows.first { receiver.owns($0) && $0 !== receiver.window })
        XCTAssertEqual(receiver.selectedSource, .testPattern)
        receiver.sourceBrowser.onActivate?(.testPattern)
        XCTAssertTrue(receiver.isFullscreen, "A second activation must not toggle fullscreen off")
        XCTAssertTrue(receiver.owns(output))
        Preferences.shared.fullscreenDisplayID = DisplayCatalog.identifier(for: external)
        XCTAssertTrue(receiver.isFullscreen)
        XCTAssertEqual(receiver.selectedSource, .testPattern, "Retargeting retains the receiver")
        XCTAssertEqual(receiver.fullscreenDisplayID, DisplayCatalog.identifier(for: external))
        let newSource = try OMTSource.manual("omt://127.0.0.1:1")
        receiver.sourceBrowser.onActivate?(newSource)
        XCTAssertEqual(receiver.selectedSource, newSource)
        XCTAssertTrue(receiver.isFullscreen)
        let switchedOutput = try XCTUnwrap(NSApp.windows.first { receiver.owns($0) && $0 !== receiver.window })
        XCTAssertEqual(switchedOutput.frame, external.frame)
        XCTAssertTrue(receiver.window?.isVisible == true)
        receiver.sourceBrowser.onEscape?()
        XCTAssertFalse(receiver.isFullscreen)
        XCTAssertNil(receiver.selectedSource)
        let stopped = expectation(description: "Browser and output retire")
        receiver.shutdown { stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 8)
        receiver.window?.close()
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
