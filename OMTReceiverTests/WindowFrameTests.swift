import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class WindowFrameTests: XCTestCase {
    func testFirstRunContentDoesNotCollapseTheWindowToItsMinimumSize() async throws {
        let name = uniqueName()
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        defer { cleanUp([receiver], names: [name]) }
        receiver.showWindow(nil)
        let window = try XCTUnwrap(receiver.window)
        XCTAssertGreaterThan(window.frame.width, window.minSize.width,
                             "Assigning the content controller must preserve the initial browsing size")
        let settled = window.frame
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, settled)
        await close(receiver)
    }

    func testSavedNativeFrameRestoresWhenTheReceiverIsShown() async throws {
        let name = uniqueName()
        let saved = try await seedFrame(name: name, width: 910, height: 610, inset: 35)
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        defer { cleanUp([receiver], names: [name]) }
        receiver.showWindow(nil)
        XCTAssertFalse(receiver.shouldCascadeWindows)
        XCTAssertEqual(receiver.windowFrameAutosaveName, name)
        XCTAssertEqual(receiver.window?.frame, saved, "Native restoration must survive content setup and showWindow")
        await close(receiver)
    }

    func testReceiverWindowsRestoreIndependentNativeFrames() async throws {
        let names = [uniqueName(), uniqueName()]
        let savedFirst = try await seedFrame(name: names[0], width: 820, height: 510, inset: 25)
        let savedSecond = try await seedFrame(name: names[1], width: 990, height: 650, inset: 65)
        let first = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: names[0])
        let second = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 2, frameAutosaveName: names[1])
        defer { cleanUp([first, second], names: names) }
        first.showWindow(nil); second.showWindow(nil)
        XCTAssertNotEqual(savedFirst, savedSecond)
        XCTAssertEqual(first.window?.frame, savedFirst)
        XCTAssertEqual(second.window?.frame, savedSecond)
        XCTAssertEqual(first.windowFrameAutosaveName, names[0])
        XCTAssertEqual(second.windowFrameAutosaveName, names[1])
        await close(first); await close(second)
    }

    func testFullscreenPreservesTheRestoredBrowserFrame() async throws {
        let name = uniqueName()
        let saved = try await seedFrame(name: name, width: 870, height: 580, inset: 45)
        let previousDisplay = Preferences.shared.fullscreenDisplayID
        Preferences.shared.fullscreenDisplayID = ""
        defer { Preferences.shared.fullscreenDisplayID = previousDisplay }
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: name)
        defer { cleanUp([receiver], names: [name]) }
        receiver.showWindow(nil)
        let browser = try XCTUnwrap(receiver.window)
        XCTAssertEqual(browser.frame, saved)
        receiver.connect(.testPattern)
        XCTAssertTrue(receiver.isFullscreen)
        let output = try XCTUnwrap(NSApp.windows.first { receiver.owns($0) && $0 !== browser })
        XCTAssertTrue(output.frameAutosaveName.isEmpty)
        XCTAssertFalse(output.isRestorable)
        XCTAssertEqual(browser.frame, saved)
        receiver.disconnect(nil)
        XCTAssertFalse(receiver.isFullscreen)
        XCTAssertEqual(browser.frame, saved)
        await close(receiver)
    }

    private func uniqueName() -> NSWindow.FrameAutosaveName { "OMTReceiver.FrameTests.\(UUID().uuidString)" }

    /// Seed through a receiver with the same native toolbar and content chrome,
    /// matching a prior launch rather than a differently configured NSWindow.
    private func seedFrame(name: NSWindow.FrameAutosaveName, width: CGFloat, height: CGFloat, inset: CGFloat) async throws -> NSRect {
        let fixtureName = uniqueName()
        let fixture = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 1, frameAutosaveName: fixtureName)
        defer { cleanUp([fixture], names: [fixtureName]) }
        let window = try XCTUnwrap(fixture.window)
        // Keep the saved geometry on the window's actual associated screen;
        // an unshown cross-display move has not received WindowServer updates.
        let visible = try XCTUnwrap(window.screen).visibleFrame
        let size = NSSize(width: min(width, visible.width - 2 * inset), height: min(height, visible.height - 2 * inset))
        let frame = NSRect(x: visible.minX + inset, y: visible.maxY - size.height - inset, width: size.width, height: size.height)
        window.setFrame(frame, display: false)
        window.saveFrame(usingName: name)
        let saved = window.frame
        await close(fixture)
        return saved
    }

    private func close(_ receiver: ReceiverWindowController) async {
        receiver.window?.close()
        let retired = expectation(description: "Window frame fixture retired")
        receiver.shutdown { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 5)
    }

    private func cleanUp(_ receivers: [ReceiverWindowController], names: [NSWindow.FrameAutosaveName]) {
        for receiver in receivers {
            // Fixtures deliberately retain closed controllers. Release their
            // native registration before removing each unique saved frame.
            receiver.windowFrameAutosaveName = ""
            receiver.window?.close()
            receiver.shutdown {}
        }
        for name in names { NSWindow.removeFrame(usingName: name) }
    }
}
