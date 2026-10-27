import AppKit
import XCTest
@testable import OMTReceiver

@MainActor
final class PlaybackInterfaceRecoveryTests: XCTestCase {
    func testAutomaticRecoveryKeepsFullscreenPictureSourceAndMuteAndEscapeCancelsRetry() async throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "A native display is required")
        let screen = try XCTUnwrap(DisplayCatalog.mainScreen)
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        let port = test_available_loopback_port()
        let sender = try XCTUnwrap(test_sender_create(library, port))
        defer { test_sender_destroy(sender) }
        let proxy = try XCTUnwrap(test_proxy_create(port))
        defer { test_proxy_destroy(proxy) }
        let source = try OMTSource.manual("omt://127.0.0.1:\(test_proxy_port(proxy))")
        let receiver = ReceiverWindowController(discovery: OMTDiscoveryManager(), number: 961, screens: { [screen] })
        // Preview recovery is tested separately. Keep thumbnail connections
        // out of this fullscreen-only connection count when Escape reveals Sources.
        await withCheckedContinuation { continuation in receiver.sourceBrowser.stop { continuation.resume() } }
        receiver.window?.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
        do {
            receiver.connect(source)
            receiver.toggleMute(nil)
            let owner = try XCTUnwrap(receiver.window)
            let presentation = try XCTUnwrap(NSApp.windows.first { receiver.owns($0) && $0 !== owner })
            let video = try XCTUnwrap(descendants(try XCTUnwrap(presentation.contentView)).compactMap { $0 as? VideoView }.first)
            video.isPaused = true
            let status = try XCTUnwrap(descendants(try XCTUnwrap(owner.contentView)).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityLabel() == "Connection status" })
            XCTAssertNil(video.errorMessage)
            var width: Int32 = 320, height: Int32 = 180
            var timestamp: Int64 = 0
            let send = {
                _ = test_sender_video(sender, width, height, 0, 0, 0, timestamp)
                _ = test_sender_audio(sender, 48000, timestamp)
                timestamp += 200_000
            }
            try await pump(until: {
                _ = video.prepareDueFrame(at: .infinity)
                return video.displayedFormat?.contains("320 × 180") == true && test_proxy_connections(proxy) == 2
            }, send: send, timeout: 8)
            let lastPicture = try XCTUnwrap(video.displayedFormat)

            test_proxy_set_offline(proxy, 1)
            try await pump(until: { test_proxy_connections(proxy) >= 4 }, send: send, timeout: 10)
            XCTAssertEqual(video.displayedFormat, lastPicture, "The previous picture must survive automatic queue reset")
            XCTAssertTrue(receiver.isFullscreen)
            XCTAssertTrue(video.window === presentation)
            XCTAssertEqual(receiver.selectedSource, source)
            XCTAssertTrue(receiver.muted)

            // Old pipes remain frozen after this transition; only another
            // fresh receiver can deliver the changed format and new epoch.
            let failedConnections = test_proxy_connections(proxy)
            test_proxy_set_offline(proxy, 0)
            width = 640; height = 360; timestamp = 0
            try await pump(until: {
                _ = video.prepareDueFrame(at: .infinity)
                return test_proxy_connections(proxy) > failedConnections && video.displayedFormat?.contains("640 × 360") == true
            }, send: send, timeout: 15)
            XCTAssertTrue(receiver.isFullscreen)
            XCTAssertTrue(video.window === presentation, "Recovery must reuse the presentation window and video surface")
            XCTAssertEqual(receiver.selectedSource, source)
            XCTAssertTrue(receiver.muted, "Recovery must preserve the receiver's mute preference")

            test_proxy_set_offline(proxy, 1)
            try await pump(until: { status.stringValue.contains("Signal lost") }, send: send, timeout: 8)
            receiver.sourceBrowser.onEscape?()
            XCTAssertFalse(receiver.isFullscreen)
            XCTAssertNil(receiver.selectedSource)
            let stoppedConnections = test_proxy_connections(proxy)
            test_proxy_set_offline(proxy, 0)
            try await pump(for: 5, send: send)
            XCTAssertEqual(test_proxy_connections(proxy), stoppedConnections,
                           "Escape must cancel a pending reconnect rather than reopen output")
            XCTAssertFalse(presentation.isVisible)
        } catch {
            await retire(receiver)
            throw error
        }
        await retire(receiver)
    }

    private func pump(until condition: () -> Bool, send: () -> Void, timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            send()
            try await Task.sleep(nanoseconds: 20_000_000)
            if condition() { return }
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Full-quality playback did not reach the expected recovery state", file: file, line: line)
        throw FixtureError.timeout
    }

    private func pump(for duration: TimeInterval, send: () -> Void) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat {
            send()
            try await Task.sleep(nanoseconds: 20_000_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
    }

    private func retire(_ receiver: ReceiverWindowController) async {
        await withCheckedContinuation { continuation in receiver.shutdown { continuation.resume() } }
        receiver.window?.close()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private enum FixtureError: Error { case timeout }
}
