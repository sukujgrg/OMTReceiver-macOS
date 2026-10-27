import XCTest
@testable import OMTReceiver

/// Real SDK connections, not simulated health states. An outage leaves each
/// affected TCP pipe open forever; only future connections can receive media.
@MainActor
final class PreviewRecoveryTests: XCTestCase {
    func testNetworkReturnAutomaticallyRecoversStalePreviewWithoutRestartingPlayback() async throws {
        try await withFixture { fixture in
            try await fixture.establishLiveReceivers()
            let playbackBeforeLoss = fixture.capture.snapshot()
            fixture.setPreviewOffline(true)

            try await fixture.pump(until: { fixture.preview.canRetry }, timeout: 8,
                                   failure: "A media-stalled thumbnail must enable Retry Preview")
            XCTAssertTrue(fixture.preview.statusText.contains("Signal lost"))
            try await fixture.pump(until: { fixture.previewConnections >= 2 }, timeout: 8,
                                   failure: "A stalled preview must automatically replace its half-open SDK connection")
            let connectionsBeforeReturn = fixture.previewConnections
            fixture.setPreviewOffline(false)
            // Existing TCP pipes stay blackholed. A Live label and a newly
            // consumed picture must therefore come from another connection.
            try await fixture.pump(until: {
                fixture.previewConnections > connectionsBeforeReturn && fixture.consumeLivePreview()
            }, timeout: 15, failure: "The preview must recover itself when the camera returns to the network")

            XCTAssertFalse(fixture.preview.canRetry)
            XCTAssertTrue(fixture.preview.formatText.contains("160 × 90"))
            fixture.assertPlaybackContinued(since: playbackBeforeLoss)
        }
    }

    func testRetryPreviewRecoversImmediatelyAndDiscardsPendingAutomaticRetry() async throws {
        try await withFixture { fixture in
            try await fixture.establishLiveReceivers()
            let playbackBeforeLoss = fixture.capture.snapshot()
            fixture.setPreviewOffline(true)
            try await fixture.pump(until: { fixture.preview.canRetry }, timeout: 8,
                                   failure: "Signal loss must enable manual preview recovery")
            let connectionsBeforeRetry = fixture.previewConnections
            fixture.setPreviewOffline(false)
            fixture.preview.retry()
            XCTAssertFalse(fixture.preview.canRetry, "An in-progress connection cannot be retried repeatedly")
            try await fixture.pump(until: {
                fixture.previewConnections > connectionsBeforeRetry && fixture.consumeLivePreview()
            }, timeout: 8, failure: "Retry Preview must replace the stalled connection immediately")
            XCTAssertEqual(fixture.previewConnections, connectionsBeforeRetry + 1)

            let recoveredConnections = fixture.previewConnections
            fixture.preview.retry() // A stale menu action cannot reset a healthy preview.
            try await fixture.pump(for: 5)
            XCTAssertEqual(fixture.previewConnections, recoveredConnections,
                           "Neither a pending automatic retry nor Retry on a healthy tile may restart it")
            XCTAssertTrue(fixture.consumeLivePreview())
            fixture.assertPlaybackContinued(since: playbackBeforeLoss)
        }
    }

    func testStoppingPreviewDuringReconnectBackoffCannotRecreateItsReceiver() async throws {
        try await withFixture { fixture in
            try await fixture.establishLiveReceivers()
            let playbackBeforeLoss = fixture.capture.snapshot()
            fixture.setPreviewOffline(true)
            try await fixture.pump(until: { fixture.preview.canRetry }, timeout: 8,
                                   failure: "The preview must enter its stalled retry state")
            await fixture.stopPreview()
            let retiredConnections = fixture.previewConnections
            fixture.setPreviewOffline(false)
            fixture.preview.retry()
            try await fixture.pump(for: 5)

            XCTAssertFalse(fixture.preview.canRetry)
            XCTAssertEqual(fixture.previewConnections, retiredConnections,
                           "A hidden or stopped preview must not reopen after its pending retry deadline")
            XCTAssertNil(fixture.preview.video.displayedFormat)
            fixture.assertPlaybackContinued(since: playbackBeforeLoss)
        }
    }

    private func withFixture(_ body: (PreviewRecoveryFixture) async throws -> Void) async throws {
        let fixture = try PreviewRecoveryFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }
}

private final class RecoveryPlaybackCapture: @unchecked Sendable {
    struct Snapshot {
        let video: Int
        let audio: Int
    }
    private let lock = NSLock()
    private var videoFrames = 0
    private var audioFrames = 0
    func video(_ frame: VideoFrame) { lock.lock(); videoFrames += 1; lock.unlock() }
    func audio(_ frame: AudioFrame) { lock.lock(); audioFrames += 1; lock.unlock() }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(video: videoFrames, audio: audioFrames)
    }
}

@MainActor
private final class PreviewRecoveryFixture {
    let preview: SourceThumbnailPreview
    let playback: ReceiverSession
    let capture: RecoveryPlaybackCapture
    private let sender: UnsafeMutableRawPointer
    private let previewProxy: UnsafeMutableRawPointer
    private let playbackProxy: UnsafeMutableRawPointer
    private var timestamp: Int64 = 0
    private var previewStopped = false
    private var playbackEstablished = false
    private var unexpectedPlaybackStatus: String?

    var previewConnections: Int32 { test_proxy_connections(previewProxy) }

    init() throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        let port = test_available_loopback_port()
        XCTAssertGreaterThan(port, 0)
        let sender = try XCTUnwrap(test_sender_create(library, port))
        guard let previewProxy = test_proxy_create(port) else {
            test_sender_destroy(sender)
            throw FixtureError.setup("Cannot create preview loopback proxy")
        }
        guard let playbackProxy = test_proxy_create(port) else {
            test_proxy_destroy(previewProxy)
            test_sender_destroy(sender)
            throw FixtureError.setup("Cannot create playback loopback proxy")
        }
        do {
            let previewSource = try OMTSource.manual("omt://127.0.0.1:\(test_proxy_port(previewProxy))")
            let playbackSource = try OMTSource.manual("omt://127.0.0.1:\(test_proxy_port(playbackProxy))")
            self.sender = sender
            self.previewProxy = previewProxy
            self.playbackProxy = playbackProxy
            let capture = RecoveryPlaybackCapture()
            self.capture = capture
            preview = SourceThumbnailPreview(source: previewSource)
            playback = ReceiverSession(video: { capture.video($0) }, audio: { capture.audio($0) })
            preview.start()
            playback.connect(playbackSource)
        } catch {
            test_proxy_destroy(previewProxy)
            test_proxy_destroy(playbackProxy)
            test_sender_destroy(sender)
            throw error
        }
    }

    func establishLiveReceivers() async throws {
        XCTAssertNil(preview.video.errorMessage)
        try await pump(until: {
            let full = self.capture.snapshot()
            return self.consumeLivePreview() && full.video >= 5 && full.audio >= 5 && self.playback.statusText == "Live"
        }, timeout: 10, failure: "Both the real SDK preview and full video/audio receiver must establish a healthy baseline")
        XCTAssertEqual(previewConnections, 1, "A silent preview has only its video TCP connection")
        XCTAssertEqual(test_proxy_connections(playbackProxy), 2, "Full playback owns one video and one audio TCP connection")
        playbackEstablished = true
    }

    func setPreviewOffline(_ offline: Bool) {
        // Consume the last pre-outage pending picture so a later assertion
        // cannot mistake a stale mailbox entry for a recovered frame.
        _ = preview.video.prepareDueFrame(at: ProcessInfo.processInfo.systemUptime)
        test_proxy_set_offline(previewProxy, offline ? 1 : 0)
    }

    func consumeLivePreview() -> Bool {
        preview.statusText == "Live" && preview.video.prepareDueFrame(at: ProcessInfo.processInfo.systemUptime)
    }

    func assertPlaybackContinued(since baseline: RecoveryPlaybackCapture.Snapshot,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let current = capture.snapshot()
        XCTAssertGreaterThan(current.video, baseline.video, file: file, line: line)
        XCTAssertGreaterThan(current.audio, baseline.audio, file: file, line: line)
        XCTAssertEqual(playback.statusText, "Live", file: file, line: line)
        XCTAssertNil(unexpectedPlaybackStatus, "Full playback must stay live throughout preview faults and retries", file: file, line: line)
        XCTAssertEqual(test_proxy_connections(playbackProxy), 2,
                       "Thumbnail recovery must never replace either fullscreen video or audio connection", file: file, line: line)
    }

    func pump(until condition: () -> Bool, timeout: TimeInterval, failure: String,
              file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            try await sendNextFrames()
            if condition() { return }
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("\(failure). Preview: \(preview.statusText); preview connections: \(previewConnections); playback: \(playback.statusText)",
                file: file, line: line)
        throw FixtureError.timeout
    }

    func pump(for duration: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat { try await sendNextFrames() } while ProcessInfo.processInfo.systemUptime < deadline
    }

    private func sendNextFrames() async throws {
        _ = test_sender_video(sender, 1280, 720, 0, 0, 0, timestamp)
        _ = test_sender_audio(sender, 48000, timestamp)
        timestamp += 333_667
        try await Task.sleep(nanoseconds: 33_366_667)
        if playbackEstablished, playback.statusText != "Live" { unexpectedPlaybackStatus = playback.statusText }
    }

    func stopPreview() async {
        guard !previewStopped else { return }
        previewStopped = true
        await withCheckedContinuation { continuation in preview.stop { continuation.resume() } }
    }

    func stop() async {
        await stopPreview()
        await withCheckedContinuation { continuation in playback.stop { continuation.resume() } }
        // Keep the upstream sender alive until no proxy thread can use it.
        test_proxy_destroy(previewProxy)
        test_proxy_destroy(playbackProxy)
        test_sender_destroy(sender)
    }

    private enum FixtureError: Error {
        case setup(String)
        case timeout
    }
}
