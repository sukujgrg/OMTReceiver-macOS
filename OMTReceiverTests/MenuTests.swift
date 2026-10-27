import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class MenuTests: XCTestCase {
    func testNativeMenuRolesAndTaskGrouping() async throws {
        // The app host registers Services once at launch. AppKit keeps that
        // registration when tests temporarily replace the menu bar, so verify
        // the native role against the launched menu, not a later generation.
        let launchedMenu = try XCTUnwrap(NSApp.mainMenu)
        let launchedAppMenu = try submenu("OMTReceiver", in: launchedMenu)
        let registeredServices = try XCTUnwrap(NSApp.servicesMenu)
        XCTAssertTrue(registeredServices === launchedAppMenu.item(withTitle: "Services")?.submenu)
        try await withMenus { _, bar in
            XCTAssertEqual(bar.items.map(\.title), ["OMTReceiver", "File", "Edit", "View", "Playback", "Window", "Help"])
            let app = try self.submenu("OMTReceiver", in: bar)
            XCTAssertEqual(Array(app.items.prefix(5)).map(\.title),
                           ["About OMTReceiver", "", "Settings…", "Check for Updates…", ""])
            XCTAssertTrue(NSApp.windowsMenu === bar.item(withTitle: "Window")?.submenu)
            XCTAssertTrue(NSApp.helpMenu === bar.item(withTitle: "Help")?.submenu)
            XCTAssertEqual(try self.submenu("File", in: bar).items.map(\.title),
                           ["New Receiver Window", "Connect to Address…", "Open Test Pattern", "", "Close Window"])
            XCTAssertEqual(try self.submenu("View", in: bar).items.map(\.title),
                           ["Show Sources", "", "Enter Full Screen"])
            XCTAssertEqual(try self.submenu("Playback", in: bar).items.map(\.title),
                           ["Mute Audio", "", "Reconnect", "Stop Output"])
            XCTAssertTrue(self.allItems(in: bar).allSatisfy { $0.view == nil },
                          "AppKit must draw ordinary menu items and their key equivalents")
        }
    }

    func testExistingKeyEquivalentsAndNativeActionTargetsArePreserved() async throws {
        try await withMenus { delegate, bar in
            let shortcuts: [(String, String, NSEvent.ModifierFlags)] = [
                ("showSettings:", ",", .command),
                ("hide:", "h", .command),
                ("hideOtherApplications:", "h", [.command, .option]),
                ("terminate:", "q", .command),
                ("newReceiver:", "n", .command),
                ("connectAddress:", "o", .command),
                ("testPattern:", "t", [.command, .option]),
                ("closeWindow:", "w", .command),
                ("undo:", "z", .command),
                ("redo:", "z", [.command, .shift]),
                ("cut:", "x", .command),
                ("copy:", "c", .command),
                ("paste:", "v", .command),
                ("selectAll:", "a", .command),
                ("toggleSidebar:", "s", [.command, .option]),
                ("toggleFullscreen:", "f", [.command, .control]),
                ("toggleMute:", "m", [.command, .shift]),
                ("reconnect:", "r", .command),
                ("disconnect:", "d", [.command, .shift]),
                ("performMiniaturize:", "m", .command),
                ("showHelp:", "?", .command)
            ]
            for (action, key, modifiers) in shortcuts {
                let item = try self.item(action, in: bar)
                XCTAssertEqual(item.keyEquivalent, key, action)
                XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, action)
            }
            for action in ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "performMiniaturize:", "performZoom:"] {
                XCTAssertNil(try self.item(action, in: bar).target,
                             "\(action) must follow the first-responder chain, including Settings text fields")
            }
            for action in ["orderFrontStandardAboutPanel:", "hide:", "hideOtherApplications:", "unhideAllApplications:", "terminate:", "arrangeInFront:"] {
                XCTAssertTrue(try self.item(action, in: bar).target === NSApp, action)
            }
            for action in ["showSettings:", "checkForUpdates:", "newReceiver:", "connectAddress:", "testPattern:", "closeWindow:",
                           "toggleSidebar:", "toggleFullscreen:", "toggleMute:", "reconnect:", "disconnect:", "showHelp:"] {
                let item = try self.item(action, in: bar)
                XCTAssertTrue(item.target === delegate, action)
                XCTAssertTrue(delegate.responds(to: item.action), action)
            }
        }
    }

    func testReceiverCommandsAreDisabledWithoutAnOwnedReceiver() async throws {
        try await withMenus { delegate, bar in
            for action in ["toggleSidebar:", "toggleFullscreen:", "toggleMute:", "reconnect:", "disconnect:"] {
                XCTAssertFalse(delegate.validateMenuItem(try self.item(action, in: bar)), action)
            }
            for action in ["newReceiver:", "connectAddress:", "testPattern:", "showSettings:", "showHelp:"] {
                XCTAssertTrue(delegate.validateMenuItem(try self.item(action, in: bar)), action)
            }
        }
    }

    func testPlaybackValidationAndDispatchFollowReceiverAndSettingsFocus() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "A native screen is required to validate presentation commands")
        // XCTest hosts need not become the WindowServer's active application.
        // Supply explicit focus snapshots with real native windows instead of
        // assuming makeKeyAndOrderFront grants the test process global focus.
        var context: (key: NSWindow?, main: NSWindow?) = (nil, nil)
        try await withMenus(windowContext: { context }) { delegate, bar in
            let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            delegate.newReceiver(nil)
            let browser = try XCTUnwrap(NSApp.windows.first {
                !previousWindows.contains(ObjectIdentifier($0)) && $0.windowController is ReceiverWindowController
            })
            let receiver = try XCTUnwrap(browser.windowController as? ReceiverWindowController)
            var settingsWindow: NSWindow?
            defer {
                receiver.shutdown {}
                browser.close()
                settingsWindow?.close()
            }
            context = (browser, browser)
            let mute = try self.item("toggleMute:", in: bar)
            let fullScreen = try self.item("toggleFullscreen:", in: bar)
            let reconnect = try self.item("reconnect:", in: bar)
            let stop = try self.item("disconnect:", in: bar)
            XCTAssertTrue(delegate.validateMenuItem(mute), "A browser can be muted before starting output")
            XCTAssertEqual(mute.state, .off)
            XCTAssertTrue(delegate.validateMenuItem(fullScreen))
            XCTAssertEqual(fullScreen.title, "Enter Full Screen")
            XCTAssertFalse(delegate.validateMenuItem(reconnect))
            XCTAssertFalse(delegate.validateMenuItem(stop))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(mute.action), to: mute.target, from: mute))
            XCTAssertTrue(receiver.muted)

            receiver.connect(.testPattern)
            let output = try XCTUnwrap(NSApp.windows.first { receiver.owns($0) && $0 !== browser })
            context = (output, browser)
            XCTAssertTrue(delegate.validateMenuItem(mute))
            XCTAssertEqual(mute.state, .on, "Starting output retains the browser's mute preference")
            XCTAssertTrue(delegate.validateMenuItem(fullScreen))
            XCTAssertEqual(fullScreen.title, "Exit Full Screen")
            XCTAssertTrue(delegate.validateMenuItem(reconnect))
            XCTAssertTrue(delegate.validateMenuItem(stop))

            context = (nil, browser)
            XCTAssertTrue(delegate.validateMenuItem(fullScreen), "The main receiver is used when there is no key window")
            delegate.showSettings(nil)
            settingsWindow = try XCTUnwrap(NSApp.windows.first {
                !previousWindows.contains(ObjectIdentifier($0)) && $0.windowController is PreferencesWindowController
            })
            context = (settingsWindow, browser)
            XCTAssertTrue(receiver.isFullscreen, "Opening Settings preserves the active output")
            for action in ["toggleSidebar:", "toggleFullscreen:", "toggleMute:", "reconnect:", "disconnect:"] {
                XCTAssertFalse(delegate.validateMenuItem(try self.item(action, in: bar)),
                               "Settings must not implicitly target another window's playback: \(action)")
            }
            XCTAssertEqual(fullScreen.title, "Enter Full Screen")
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(mute.action), to: mute.target, from: mute))
            XCTAssertTrue(receiver.muted, "Action dispatch must also respect Settings focus")

            context = (browser, browser)
            XCTAssertTrue(delegate.validateMenuItem(stop))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(stop.action), to: stop.target, from: stop))
            XCTAssertNil(receiver.selectedSource)
            XCTAssertFalse(receiver.isFullscreen)
            XCTAssertFalse(delegate.validateMenuItem(stop))
            XCTAssertTrue(delegate.validateMenuItem(mute))
            XCTAssertEqual(mute.state, .on)
            let retired = self.expectation(description: "Menu receiver workers retired")
            receiver.shutdown { retired.fulfill() }
            await self.fulfillment(of: [retired], timeout: 5)
        }
    }

    private func withMenus(
        windowContext: @escaping @MainActor () -> (key: NSWindow?, main: NSWindow?) = { (nil, nil) },
        _ body: @MainActor (AppDelegate, NSMenu) async throws -> Void
    ) async throws {
        let previousMain = NSApp.mainMenu
        let previousServices = NSApp.servicesMenu
        let previousWindows = NSApp.windowsMenu
        let previousHelp = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMain
            NSApp.servicesMenu = previousServices
            NSApp.windowsMenu = previousWindows
            NSApp.helpMenu = previousHelp
        }
        let delegate = AppDelegate(windowContext: windowContext)
        delegate.makeMenus()
        try await body(delegate, XCTUnwrap(NSApp.mainMenu))
    }

    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(menu.item(withTitle: title)?.submenu, title)
    }

    private func item(_ action: String, in menu: NSMenu) throws -> NSMenuItem {
        let matches = allItems(in: menu).filter { $0.action == NSSelectorFromString(action) }
        XCTAssertEqual(matches.count, 1, "Command must appear exactly once: \(action)")
        return try XCTUnwrap(matches.first, action)
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map { allItems(in: $0) } ?? []) }
    }
}
