import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class WindowFrameTests: XCTestCase {
    func testClosedReceiverRestoresItsResizedFrameWhenShownAgain() async throws {
        let name = uniqueName()
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        let firstWindow = try XCTUnwrap(first.window)
        var receivers = [first]
        defer { cleanUp(receivers, names: [name]) }
        first.showWindow(nil)
        firstWindow.setFrame(try frame(width: 910, height: 610, inset: 35), display: true)
        let saved = firstWindow.frame
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)"),
                        "AppKit must autosave a normal resize without custom preference writes")
        await close(first)
        XCTAssertEqual(firstWindow.frameAutosaveName, "", "A retained closed window must release its autosave slot")

        let reopened = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        receivers.append(reopened)
        reopened.showWindow(nil)
        XCTAssertFalse(reopened.shouldCascadeWindows)
        XCTAssertEqual(reopened.window?.frameAutosaveName, name)
        XCTAssertEqual(reopened.window?.frame, saved, "Showing the window must preserve the restored size and position")
        await close(reopened)
    }

    func testReceiverWindowsRestoreIndependentFramesInsteadOfCascadingSavedPositions() async throws {
        let names = [uniqueName(), uniqueName()]
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: names[0])
        let second = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 2, frameAutosaveName: names[1])
        var receivers = [first, second]
        defer { cleanUp(receivers, names: names) }
        first.showWindow(nil); second.showWindow(nil)
        first.window?.setFrame(try frame(width: 820, height: 510, inset: 25), display: true)
        second.window?.setFrame(try frame(width: 990, height: 650, inset: 65), display: true)
        let savedFirst = try XCTUnwrap(first.window?.frame)
        let savedSecond = try XCTUnwrap(second.window?.frame)
        XCTAssertNotEqual(savedFirst, savedSecond)
        await close(first); await close(second)

        let restoredFirst = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: names[0])
        let restoredSecond = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 2, frameAutosaveName: names[1])
        receivers += [restoredFirst, restoredSecond]
        restoredFirst.showWindow(nil); restoredSecond.showWindow(nil)
        XCTAssertEqual(restoredFirst.window?.frame, savedFirst)
        XCTAssertEqual(restoredSecond.window?.frame, savedSecond)
        XCTAssertEqual(restoredFirst.window?.frameAutosaveName, names[0])
        XCTAssertEqual(restoredSecond.window?.frameAutosaveName, names[1])
        await close(restoredFirst); await close(restoredSecond)
    }

    func testClosingFullscreenOutputPreservesTheBrowserFrameForReopening() async throws {
        let name = uniqueName()
        let previousDisplay = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = previousDisplay }
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        var receivers = [first]
        defer { cleanUp(receivers, names: [name]) }
        first.showWindow(nil)
        let browser = try XCTUnwrap(first.window)
        browser.setFrame(try frame(width: 870, height: 580, inset: 45), display: true)
        let saved = browser.frame
        first.connect(.testPattern)
        XCTAssertTrue(first.isFullscreen)
        let output = try XCTUnwrap(NSApp.windows.first { first.owns($0) && $0 !== browser })
        XCTAssertTrue(output.frameAutosaveName.isEmpty, "The temporary fullscreen surface must not own browser preferences")
        XCTAssertFalse(output.isRestorable)
        XCTAssertEqual(browser.frame, saved)
        await close(first)
        XCTAssertFalse(first.isFullscreen)

        let reopened = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        receivers.append(reopened)
        reopened.showWindow(nil)
        XCTAssertEqual(reopened.window?.frame, saved, "A display-sized output must never replace the saved browser frame")
        await close(reopened)
    }

    func testAppDelegateReusesTheClosedBrowserFrameSlot() async throws {
        _ = try XCTUnwrap(DisplayCatalog.mainScreen)
        let delegate = AppDelegate()
        var knownWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        var receivers: [ReceiverWindowController] = []
        var names: [NSWindow.FrameAutosaveName] = []
        defer { cleanUp(receivers, names: names) }
        func newReceiver() throws -> ReceiverWindowController {
            delegate.newReceiver(nil)
            let window = try XCTUnwrap(NSApp.windows.first {
                !knownWindows.contains(ObjectIdentifier($0)) && $0.windowController is ReceiverWindowController
            })
            knownWindows.insert(ObjectIdentifier(window))
            return try XCTUnwrap(window.windowController as? ReceiverWindowController)
        }
        let first = try newReceiver()
        receivers.append(first)
        let firstWindow = try XCTUnwrap(first.window)
        let name = firstWindow.frameAutosaveName
        names.append(name)
        XCTAssertTrue(name.hasPrefix("OMTReceiver.Test.\(ProcessInfo.processInfo.processIdentifier)."),
                      "AppKit autosaving must not touch the operator's ReceiverWindow1 defaults from the test host")
        firstWindow.setFrame(try frame(width: 930, height: 620, inset: 55), display: true)
        let saved = firstWindow.frame
        firstWindow.close()

        // Retain the closed controller and window deliberately: reuse must not
        // wait for an autorelease pool or asynchronous media retirement before
        // an immediate File > New. Do not yield before constructing this window.
        let reopened = try newReceiver()
        receivers.append(reopened)
        XCTAssertEqual(reopened.window?.frameAutosaveName, name)
        XCTAssertEqual(reopened.window?.frame, saved)

        // An already-retired controller cannot free the slot of its replacement.
        first.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))
        let additional = try newReceiver()
        receivers.append(additional)
        let additionalName = try XCTUnwrap(additional.window?.frameAutosaveName)
        names.append(additionalName)
        XCTAssertNotEqual(additionalName, name)
        await close(first)
        await close(reopened); await close(additional)
    }

    private func uniqueName() -> NSWindow.FrameAutosaveName { "OMTReceiver.FrameTests.\(UUID().uuidString)" }

    private func frame(width: CGFloat, height: CGFloat, inset: CGFloat) throws -> NSRect {
        let visible = try XCTUnwrap(DisplayCatalog.mainScreen).visibleFrame
        let size = NSSize(width: min(width, visible.width - 2 * inset), height: min(height, visible.height - 2 * inset))
        return NSRect(x: visible.minX + inset, y: visible.maxY - size.height - inset, width: size.width, height: size.height)
    }

    private func close(_ receiver: ReceiverWindowController) async {
        receiver.window?.close()
        let retired = expectation(description: "Window frame fixture retired")
        receiver.shutdown { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 5)
    }

    private func cleanUp(_ receivers: [ReceiverWindowController], names: [NSWindow.FrameAutosaveName]) {
        for receiver in receivers {
            receiver.window?.close()
            receiver.shutdown {}
        }
        for name in names { NSWindow.removeFrame(usingName: name) }
    }
}
