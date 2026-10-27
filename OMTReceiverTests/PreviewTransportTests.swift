import XCTest
@testable import OMTReceiver

private final class PreviewCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var first: VideoFrame?
    private var frames = 0
    private var audioFrames = 0
    private var firstArrival: TimeInterval?
    private var lastArrival: TimeInterval?
    func video(_ frame: VideoFrame) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = frame }
        let now = ProcessInfo.processInfo.systemUptime
        if firstArrival == nil { firstArrival = now }
        lastArrival = now; frames += 1
    }
    func audio(_ frame: AudioFrame) { lock.lock(); audioFrames += 1; lock.unlock() }
    func snapshot() -> (first: VideoFrame?, frames: Int, audioFrames: Int, duration: Double) {
        lock.lock(); defer { lock.unlock() }
        return (first, frames, audioFrames, max(0, (lastArrival ?? 0) - (firstArrival ?? 0)))
    }
}

@MainActor
final class PreviewTransportTests: XCTestCase {
    func testSDKPreviewIsReducedVideoOnlyAlongsideFullPlayback() async throws {
        XCTAssertNil(OMTSDKRuntime.shared.load())
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL?.appendingPathComponent("OMT/libomt.dylib").path)
        let port = 45000 + Int(getpid() % 10000)
        let sender = try XCTUnwrap(test_sender_create(library, Int32(port)))
        defer { test_sender_destroy(sender) }
        let source = try OMTSource.manual("omt://127.0.0.1:\(port)")
        let previewCapture = PreviewCapture(), playbackCapture = PreviewCapture()
        let preview = ReceiverSession(video: { previewCapture.video($0) },
            audio: { previewCapture.audio($0) }, mode: .preview)
        let playback = ReceiverSession(video: { playbackCapture.video($0) },
            audio: { playbackCapture.audio($0) })
        preview.connect(source); playback.connect(source)
        for step in 0..<150 {
            _ = test_sender_video(sender, 1280, 720, 0, 1, 0, Int64(step) * 166_833)
            if step % 2 == 0 { _ = test_sender_audio(sender, 48000, Int64(step) * 166_833) }
            try await Task.sleep(nanoseconds: 16_683_333)
            let thumbnail = previewCapture.snapshot(), full = playbackCapture.snapshot()
            if thumbnail.frames >= 8 && full.frames >= 8 && full.audioFrames > 0 && test_sender_connections(sender) == 3 { break }
        }
        let thumbnail = previewCapture.snapshot(), full = playbackCapture.snapshot()
        let connections = test_sender_connections(sender)
        await retire(preview); await retire(playback)
        let small = try XCTUnwrap(thumbnail.first), original = try XCTUnwrap(full.first)
        XCTAssertEqual(original.width, 1280); XCTAssertEqual(original.height, 720)
        XCTAssertLessThan(small.width, original.width); XCTAssertLessThan(small.height, original.height)
        XCTAssertEqual(small.width, 160); XCTAssertEqual(small.height, 90)
        XCTAssertEqual(small.flags & 8, 8)
        XCTAssertTrue(small.hasAlpha)
        XCTAssertEqual(small.displayAspect, original.displayAspect, accuracy: 0.0001)
        XCTAssertEqual(thumbnail.audioFrames, 0, "Thumbnails must never subscribe to/play source audio")
        XCTAssertEqual(connections, 3,
            "One preview-video connection plus full video/audio must not open a fourth audio connection")
        XCTAssertGreaterThan(full.audioFrames, 0, "This same sender supplied active audio to full playback")
        XCTAssertGreaterThanOrEqual(thumbnail.frames, 8)
        XCTAssertLessThanOrEqual(Double(thumbnail.frames), thumbnail.duration * 15 + 2,
            "Preview callback delivery is bounded before copying SDK frames")
    }

    func testPreviewPatternUsesThumbnailSizeAndStopsBeforeReplacement() async throws {
        let capture = PreviewCapture()
        let preview = ReceiverSession(video: { capture.video($0) }, audio: { capture.audio($0) }, mode: .preview)
        for _ in 0..<10 { preview.connect(.testPattern); preview.disconnect() }
        preview.connect(.testPattern)
        let deadline = Date().addingTimeInterval(3)
        while capture.snapshot().frames < 3 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await retire(preview)
        let snapshot = capture.snapshot()
        let frame = try XCTUnwrap(snapshot.first)
        XCTAssertEqual(frame.width, 320); XCTAssertEqual(frame.height, 180)
        XCTAssertEqual(frame.frameRateN, 15); XCTAssertEqual(frame.flags & 8, 8)
        XCTAssertEqual(snapshot.audioFrames, 0)
        XCTAssertNil(preview.source)
        // Retirement completion is the fence: no admitted callback follows it.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(capture.snapshot().frames, snapshot.frames)
    }

    func testPreviewValidationRetainsTheSDKOriginalColorDefaultAndSmallSizes() throws {
        // The SDK has already decoded using originalHeight: these returned
        // preview dimensions must not make an HD709 source look like SD601.
        for (height, flags, expected) in [(90, 8, 709), (134, 9, 709), (72, 8, 601), (88, 9, 601)] {
            let data = Data(repeating: 128, count: 160 * 2 * height)
            try data.withUnsafeBytes { bytes in
                var raw = OMTRFrame()
                raw.width = 160; raw.height = Int32(height); raw.stride = 320
                raw.codec = 0x59565955; raw.flags = Int32(flags)
                raw.frameRateN = 60000; raw.frameRateD = 1001
                raw.colorSpace = 0; raw.data = bytes.baseAddress; raw.dataLength = Int32(data.count)
                let frame = try XCTUnwrap(ReceiverSession.validatedVideo(raw, receivedAt: 0))
                XCTAssertEqual(frame.colorSpace, expected)
            }
        }
        let data = Data(repeating: 128, count: 2 * 2 * 2)
        data.withUnsafeBytes { bytes in
            var raw = OMTRFrame()
            raw.width = 2; raw.height = 2; raw.stride = 4; raw.codec = 0x59565955
            raw.flags = 8; raw.frameRateN = 30; raw.frameRateD = 1
            raw.data = bytes.baseAddress; raw.dataLength = Int32(data.count)
            XCTAssertNotNil(ReceiverSession.validatedVideo(raw, receivedAt: 0))
            raw.flags = 0
            XCTAssertNil(ReceiverSession.validatedVideo(raw, receivedAt: 0), "Tiny dimensions are preview-only")
            raw.width = 16; raw.height = 16; raw.stride = 32; raw.dataLength = 512
            // Truncated backing remains rejected for either kind of frame.
            raw.flags = 8
            raw.dataLength = 7
            XCTAssertNil(ReceiverSession.validatedVideo(raw, receivedAt: 0))
        }
    }

    private func retire(_ session: ReceiverSession) async {
        await withCheckedContinuation { continuation in session.stop { continuation.resume() } }
    }
}
